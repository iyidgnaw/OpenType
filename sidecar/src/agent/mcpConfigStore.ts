import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

export type McpTransport = "stdio" | "http";

/**
 * One MCP server as persisted by `McpConfigStore`. `transport` decides which
 * half of the record is meaningful: stdio uses `command`/`args`/`env`, http
 * uses `url`/`headers`. The other half is dropped at normalization time rather
 * than carried along as dead fields (see `normalizeMcpServer`), so a server
 * switched from stdio to http cannot keep stale credentials it no longer has
 * any use for.
 */
export interface StoredMcpServer {
  name: string;
  transport: McpTransport;
  /** stdio only. */
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  /** http only. */
  url?: string;
  headers?: Record<string, string>;
  /**
   * Whether this server is offered to the boot path at all.
   *
   * Exists so a server that fails its connection test can still be **saved**
   * rather than forcing the user to throw away the token they just typed —
   * saved disabled, and left out of the next start. Defaults to `true` when
   * absent, which is what every config already on a user's disk looks like:
   * defaulting to `false` would silently switch off everyone's working servers
   * on upgrade.
   */
  enabled: boolean;
}

export interface McpConfigStatus {
  mcpConfigured: boolean;
}

/** Which of the two config sources actually supplied the resolved servers. */
export type McpConfigSource = "saved" | "env";

export interface ResolvedMcpServers {
  source: McpConfigSource;
  /** Only the enabled ones -- this is what the boot path connects. */
  servers: StoredMcpServer[];
  /**
   * Everything from the resolved source, disabled included, so the Settings
   * panel can list a disabled server and offer to switch it back on. A UI that
   * could only see `servers` would make a disabled server invisible and
   * therefore unrecoverable, which defeats the point of saving it disabled.
   */
  allServers: StoredMcpServer[];
}

/**
 * A caller error: the submitted server is malformed, or violates the store's
 * name-uniqueness rule. Distinct from an I/O failure so the HTTP layer can map
 * exactly this class to a 400 and let a genuine write failure surface as a 500
 * (`agent/mcpConfigRoutes.ts`).
 */
export class McpConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "McpConfigError";
  }
}

/**
 * A server's tools reach the model as `${serverName}__${toolName}` (see
 * `connectConfiguredMcpServers`), and OpenAI-style function names are limited
 * to `[A-Za-z0-9_-]`. A name outside that charset therefore produces tool
 * descriptors the provider rejects -- which fails the *entire* request, not
 * just that server's tools -- so it is refused here, at the point the user
 * types it, rather than discovered later as a broken agent run.
 */
const NAME_PATTERN = /^[A-Za-z0-9_-]+$/;

interface McpConfigFile {
  servers: StoredMcpServer[];
  mcpConfigured: boolean;
}

const EMPTY_FILE: McpConfigFile = { servers: [], mcpConfigured: false };

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeName(raw: unknown): string {
  if (typeof raw !== "string") {
    throw new McpConfigError("name is required");
  }
  const name = raw.trim();
  if (name.length === 0) {
    throw new McpConfigError("name is required");
  }
  if (!NAME_PATTERN.test(name)) {
    throw new McpConfigError(
      `name must contain only letters, digits, "_" or "-" (it becomes half of a tool name), got: ${raw}`,
    );
  }
  return name;
}

function normalizeStringMap(
  raw: unknown,
  field: string,
): Record<string, string> | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (!isPlainObject(raw)) {
    throw new McpConfigError(`${field} must be an object of string values`);
  }
  const entries = Object.entries(raw);
  if (entries.length === 0) {
    // Canonical form for "no entries" is absence, so an emptied map and an
    // omitted one are stored identically.
    return undefined;
  }
  const out: Record<string, string> = {};
  for (const [key, value] of entries) {
    if (typeof value !== "string") {
      throw new McpConfigError(`${field}.${key} must be a string`);
    }
    out[key] = value;
  }
  return out;
}

/**
 * Validates + canonicalizes one submitted server, throwing `McpConfigError`
 * on anything a user could get wrong. Pure: callers use it to check a
 * candidate (`POST /config/mcp/test`) without saving it.
 *
 * A missing `transport` defaults to stdio, because the `OPENTYPE_MCP_SERVERS`
 * format documented before this store existed (`{name, command, args}`) has no
 * such field and must keep working.
 *
 * The url is deliberately NOT normalized the way `ProviderConfigStore`
 * normalizes a provider baseUrl: that one gets a path appended to it, whereas
 * an MCP endpoint URL is used whole and its path is server-defined, so it is
 * only validated (parseable, http/https) and then stored exactly as given.
 */
export function normalizeMcpServer(input: unknown): StoredMcpServer {
  if (!isPlainObject(input)) {
    throw new McpConfigError("server must be an object");
  }
  const name = normalizeName(input.name);
  // Absent (or null) means enabled: configs written before this field existed,
  // and every hand-written env entry, must keep working rather than silently
  // going dark. Anything else that is not a boolean is refused rather than
  // coerced -- `enabled: "false"` coerced to `true` would quietly connect a
  // server the user believed was off, which is the one direction of this
  // mistake that has consequences.
  if (
    input.enabled !== undefined &&
    input.enabled !== null &&
    typeof input.enabled !== "boolean"
  ) {
    throw new McpConfigError(
      `enabled must be a boolean, got: ${String(input.enabled)}`,
    );
  }
  const enabled = input.enabled === undefined || input.enabled === null
    ? true
    : input.enabled;
  const rawTransport = input.transport ?? "stdio";
  if (rawTransport !== "stdio" && rawTransport !== "http") {
    throw new McpConfigError(
      `transport must be "stdio" or "http", got: ${String(rawTransport)}`,
    );
  }

  if (rawTransport === "http") {
    const url = input.url;
    if (typeof url !== "string" || url.trim().length === 0) {
      throw new McpConfigError("url is required for an http server");
    }
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new McpConfigError(`url is not a valid URL: ${url}`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new McpConfigError(
        `url must use http or https, got: ${parsed.protocol}`,
      );
    }
    return {
      name,
      transport: "http",
      url,
      headers: normalizeStringMap(input.headers, "headers"),
      enabled,
    };
  }

  const command = input.command;
  if (typeof command !== "string" || command.trim().length === 0) {
    throw new McpConfigError("command is required for a stdio server");
  }
  let args: string[] = [];
  if (input.args !== undefined && input.args !== null) {
    if (!Array.isArray(input.args)) {
      throw new McpConfigError("args must be an array of strings");
    }
    for (const arg of input.args) {
      if (typeof arg !== "string") {
        throw new McpConfigError("args must be an array of strings");
      }
    }
    args = [...(input.args as string[])];
  }
  return {
    name,
    transport: "stdio",
    command: command.trim(),
    args,
    env: normalizeStringMap(input.env, "env"),
    enabled,
  };
}

function cloneServer(server: StoredMcpServer): StoredMcpServer {
  return {
    ...server,
    ...(server.args ? { args: [...server.args] } : {}),
    ...(server.env ? { env: { ...server.env } } : {}),
    ...(server.headers ? { headers: { ...server.headers } } : {}),
  };
}

/**
 * Persists the MCP servers the Settings "MCP 服务器" panel manages, so a
 * packaged-app user can finally attach tools to Agent mode -- until this
 * store, `OPENTYPE_MCP_SERVERS` was the only way in and a `.app` user has no
 * way to set it (P2-13,
 * `docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
 *
 * Storage conventions are `ProviderConfigStore`'s
 * (`src/provider/configStore.ts`), deliberately copied rather than reinvented:
 * plain JSON on local disk next to the SQLite data directory, written to a
 * fresh `0600` temp file and atomically renamed into place (no broad-mode or
 * observably-truncated window over a file holding tokens), and a corrupt file
 * self-heals -- original bytes preserved aside, logged, boot continues empty
 * -- because this store is constructed during sidecar boot and throwing there
 * would brick the whole process, transcribe-only users included. The same
 * documented plaintext tradeoff applies: an MCP server's `env`/`headers`
 * routinely carry real credentials and they sit here in the clear, protected
 * by `0600` rather than by Keychain, for exactly the reasons that store's doc
 * comment sets out.
 *
 * `mcpConfigured` is explicit, never ambient: only a real mutation through
 * this store sets it. An `OPENTYPE_MCP_SERVERS` in the environment is a
 * zero-config dev fallback, not a user decision -- see `resolveMcpServers`.
 */
export class McpConfigStore {
  private readonly path: string;
  private file: McpConfigFile;

  constructor(path: string) {
    this.path = path;
    this.file = this.load();
  }

  private load(): McpConfigFile {
    if (!existsSync(this.path)) {
      return { ...EMPTY_FILE, servers: [] };
    }
    let raw: string;
    try {
      raw = readFileSync(this.path, "utf8");
    } catch {
      // Unreadable for a reason other than absence -- boot unconfigured
      // rather than bricking the sidecar.
      return { ...EMPTY_FILE, servers: [] };
    }
    // A genuinely empty (zero-length) file -- e.g. a crash-truncated write --
    // is not corruption worth preserving; just boot cleanly unconfigured.
    if (raw.length === 0) {
      return { ...EMPTY_FILE, servers: [] };
    }
    try {
      const parsed = JSON.parse(raw) as Partial<McpConfigFile>;
      const servers: StoredMcpServer[] = [];
      if (Array.isArray(parsed.servers)) {
        for (const entry of parsed.servers) {
          try {
            servers.push(normalizeMcpServer(entry));
          } catch (err) {
            // Only normalized records are ever written, so this means the file
            // was hand-edited. Drop the bad row loudly instead of refusing to
            // boot over it.
            console.warn(
              `[McpConfigStore] Dropping unusable MCP server entry from ${this.path}: ${String(err)}`,
            );
          }
        }
      }
      return { servers, mcpConfigured: parsed.mcpConfigured === true };
    } catch (err) {
      const corruptPath = `${this.path}.corrupt-${Date.now()}`;
      try {
        renameSync(this.path, corruptPath);
      } catch {
        // If we can't rename it aside, still don't block boot.
      }
      console.error(
        `[McpConfigStore] Corrupt MCP server config at ${this.path}; ` +
          `preserved original bytes to ${corruptPath} and starting ` +
          `unconfigured. Parse error: ${String(err)}`,
      );
      return { ...EMPTY_FILE, servers: [] };
    }
  }

  private persist(): void {
    const dir = dirname(this.path);
    if (dir && dir !== "." && !existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    const data = JSON.stringify(this.file, null, 2);
    // Atomic write, identical to ProviderConfigStore.persist(): a fresh temp
    // file 0600 from the start (no world-readable window over the plaintext
    // tokens), then an atomic rename so the destination is only ever replaced
    // whole. A leftover temp is cleaned up on failure.
    const tmpPath = `${this.path}.tmp-${process.pid}-${Date.now()}`;
    try {
      writeFileSync(tmpPath, data, { mode: 0o600 });
      renameSync(tmpPath, this.path);
    } catch (err) {
      try {
        if (existsSync(tmpPath)) {
          rmSync(tmpPath, { force: true });
        }
      } catch {
        // best-effort cleanup
      }
      throw err;
    }
  }

  getStatus(): McpConfigStatus {
    return { mcpConfigured: this.file.mcpConfigured };
  }

  listServers(): StoredMcpServer[] {
    return this.file.servers.map(cloneServer);
  }

  getServer(name: string): StoredMcpServer | undefined {
    const found = this.file.servers.find((server) => server.name === name);
    return found ? cloneServer(found) : undefined;
  }

  /** Appends a new server. Throws `McpConfigError` if invalid or duplicate. */
  addServer(server: StoredMcpServer | unknown): StoredMcpServer {
    const normalized = normalizeMcpServer(server);
    if (this.file.servers.some((existing) => existing.name === normalized.name)) {
      throw new McpConfigError(`An MCP server named "${normalized.name}" already exists`);
    }
    this.file = {
      servers: [...this.file.servers, normalized],
      mcpConfigured: true,
    };
    this.persist();
    return cloneServer(normalized);
  }

  /**
   * Replaces the server currently called `name` wholesale (a replace, not a
   * patch), keeping its position in the list. The replacement may carry a
   * different name, as long as no *other* server already holds it.
   */
  updateServer(name: string, server: StoredMcpServer | unknown): StoredMcpServer {
    const index = this.file.servers.findIndex((existing) => existing.name === name);
    if (index === -1) {
      throw new McpConfigError(`No MCP server named "${name}"`);
    }
    const normalized = normalizeMcpServer(server);
    const clashes = this.file.servers.some(
      (existing, i) => i !== index && existing.name === normalized.name,
    );
    if (clashes) {
      throw new McpConfigError(`An MCP server named "${normalized.name}" already exists`);
    }
    const servers = [...this.file.servers];
    servers[index] = normalized;
    this.file = { servers, mcpConfigured: true };
    this.persist();
    return cloneServer(normalized);
  }

  /** @returns whether a server by that name existed (and was removed). */
  removeServer(name: string): boolean {
    const index = this.file.servers.findIndex((existing) => existing.name === name);
    if (index === -1) {
      // A no-op delete is not the user taking ownership of MCP config, so it
      // must not flip `mcpConfigured` or write a file.
      return false;
    }
    const servers = [...this.file.servers];
    servers.splice(index, 1);
    this.file = { servers, mcpConfigured: true };
    this.persist();
    return true;
  }
}

/**
 * Parses the `OPENTYPE_MCP_SERVERS` fallback format: a JSON array of
 * `{name, command, args}` (no `transport` -- it predates this store, so its
 * entries default to stdio). Never throws: an unset/unparseable/non-array
 * value, or an individual unusable entry, degrades to "no servers" with a
 * warning, because this runs on the sidecar's boot path.
 */
function parseEnvServers(envJson: string | undefined): StoredMcpServer[] {
  if (!envJson) {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(envJson);
  } catch {
    console.warn(
      "OPENTYPE_MCP_SERVERS is not valid JSON; starting with no MCP servers configured.",
    );
    return [];
  }
  if (!Array.isArray(parsed)) {
    console.warn(
      "OPENTYPE_MCP_SERVERS did not parse to a JSON array; starting with no MCP servers configured.",
    );
    return [];
  }
  const servers: StoredMcpServer[] = [];
  for (const entry of parsed) {
    try {
      servers.push(normalizeMcpServer(entry));
    } catch (err) {
      console.warn(`Skipping an OPENTYPE_MCP_SERVERS entry: ${String(err)}`);
    }
  }
  return servers;
}

/**
 * Decides which MCP servers this sidecar actually runs with.
 *
 * Saved config wins, and wins *entirely* -- env servers are never merged in.
 * Once the user has taken ownership (any mutation through the store sets
 * `mcpConfigured`), an emptied list means "no MCP servers", not "fall back to
 * whatever the env var said": a dev who adds then removes a server through the
 * UI must not have the env servers quietly reinstated behind their back.
 *
 * The mirror of that rule is that an ambient env var alone never reports as
 * configured -- same "configured is explicit, never ambient" stance
 * `ProviderConfigStore.getStatus` takes for LLM/Whisper.
 */
export function resolveMcpServers(
  store: McpConfigStore,
  envJson: string | undefined,
): ResolvedMcpServers {
  // Disabled servers are filtered out here rather than skipped at connect
  // time, so "disabled" means the boot path never learns about them at all --
  // no transport spawned, no budget spent, nothing to hang on.
  if (store.getStatus().mcpConfigured) {
    const allServers = store.listServers();
    return {
      source: "saved",
      servers: allServers.filter((server) => server.enabled !== false),
      allServers,
    };
  }
  const allServers = parseEnvServers(envJson);
  return {
    source: "env",
    servers: allServers.filter((server) => server.enabled !== false),
    allServers,
  };
}
