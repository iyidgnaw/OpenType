import type { Route } from "../router";
import { maskApiKey } from "../provider/maskApiKey";
import { probeMcpServer as defaultProbeMcpServer, type McpProbeResult } from "./mcpClient";
import {
  McpConfigError,
  McpConfigStore,
  normalizeMcpServer,
  resolveMcpServers,
  type StoredMcpServer,
} from "./mcpConfigStore";

/**
 * One server as reported back to the UI. Secrets appear **only** under
 * `envMasked`/`headersMasked` -- a separate key from the one they were
 * submitted under, exactly the way `provider/routes.ts` answers with
 * `apiKeyMasked` rather than `apiKey`, so a masked value can never be mistaken
 * for a real one by shape alone. Map *keys* are not masked: the user needs to
 * see that `GITHUB_TOKEN` is set, just not what it is set to.
 */
interface MaskedMcpServer {
  name: string;
  transport: string;
  command?: string;
  args?: string[];
  url?: string;
  envMasked?: Record<string, string>;
  headersMasked?: Record<string, string>;
}

export interface McpConfigRouteDeps {
  /** Overridable so `/config/mcp/test` needs no child process or network. */
  probeMcpServer: (server: StoredMcpServer) => Promise<McpProbeResult>;
  /**
   * `server.ts` passes `process.env.OPENTYPE_MCP_SERVERS`. Injected rather
   * than read here so the precedence branch of `GET /config/mcp` is testable
   * without mutating the process environment -- and so an ambient env var
   * can never leak into a test's expectations.
   */
  envJson: string | undefined;
}

const defaultDeps: McpConfigRouteDeps = {
  probeMcpServer: defaultProbeMcpServer,
  envJson: undefined,
};

function maskMap(
  map: Record<string, string> | undefined,
): Record<string, string> | undefined {
  if (!map) {
    return undefined;
  }
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(map)) {
    out[key] = maskApiKey(value);
  }
  return out;
}

function maskServer(server: StoredMcpServer): MaskedMcpServer {
  return {
    name: server.name,
    transport: server.transport,
    command: server.command,
    args: server.args,
    url: server.url,
    envMasked: maskMap(server.env),
    headersMasked: maskMap(server.headers),
  };
}

/**
 * Resolves submitted secret values against the ones already stored for **this
 * same server** (the one the URL addresses): a value equal to the mask of the
 * stored value for that same key means "unchanged", anything else is a genuine
 * new secret.
 *
 * Two scoping rules make this safe, and both are load-bearing:
 *
 *  - Resolution is per *server*, never a search across the whole config for a
 *    stored value whose mask matches. A global lookup would turn the mask into
 *    a read primitive -- paste the mask shown for one server's token into a
 *    second server's config and the sidecar would hand that second (possibly
 *    attacker-named) endpoint the first one's real credential.
 *  - Resolution is per *key*, for the same reason at smaller scale: a mask
 *    copied onto a different key has no stored counterpart and is therefore a
 *    literal value, never a wildcard that reads some other key's secret.
 *
 * On a create there is nothing stored to preserve, so `stored` is undefined
 * and a mask-shaped value is taken at face value -- there is nothing else it
 * could mean.
 */
function resolveMaskedSecrets(
  submitted: unknown,
  stored: Record<string, string> | undefined,
): unknown {
  if (submitted === undefined || submitted === null) {
    return undefined;
  }
  if (typeof submitted !== "object" || Array.isArray(submitted)) {
    // Hand the malformed value straight through; `normalizeMcpServer` rejects
    // it with a proper message rather than this function inventing one.
    return submitted;
  }
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(submitted as Record<string, unknown>)) {
    const storedValue = stored?.[key];
    if (
      typeof value === "string" &&
      storedValue !== undefined &&
      value === maskApiKey(storedValue)
    ) {
      out[key] = storedValue;
    } else {
      out[key] = value as string;
    }
  }
  return out;
}

/**
 * Builds the candidate server a write/probe should act on: the submitted body
 * with its `env`/`headers` masks resolved against `stored`, then validated.
 *
 * This is a *replace*, not a patch -- a key absent from the submitted map is
 * gone, and so is the whole map when the body omits it. That is only safe
 * because of the mask round-trip above (the UI sends every key back, untouched
 * ones carrying their masks), and it is what makes "delete this env var"
 * expressible at all. Collapsing "omitted" and "explicitly empty" is
 * deliberate: the mask round-trip stays the single way a secret survives a
 * write, rather than there also being a quieter one no UI exercises.
 */
function candidateFrom(
  body: unknown,
  stored: StoredMcpServer | undefined,
): StoredMcpServer {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new McpConfigError("request body must be a JSON object");
  }
  const raw = body as Record<string, unknown>;
  return normalizeMcpServer({
    ...raw,
    env: resolveMaskedSecrets(raw.env, stored?.env),
    headers: resolveMaskedSecrets(raw.headers, stored?.headers),
  });
}

/**
 * Maps exactly the caller-error class to a 400, and rethrows anything else --
 * a genuine write failure (a full disk, a permissions problem) must surface as
 * the 500 it is rather than be reported to the user as a bad request.
 */
function badRequest(error: unknown): Response {
  if (error instanceof McpConfigError) {
    return Response.json({ error: error.message }, { status: 400 });
  }
  throw error;
}

/** The `:name` segment of `/config/mcp/:name`. */
function serverNameFromPath(req: Request): string {
  const pathname = new URL(req.url).pathname;
  const last = pathname.split("/").pop() ?? "";
  try {
    return decodeURIComponent(last);
  } catch {
    return last;
  }
}

/**
 * HTTP surface backing the Settings "MCP 服务器" panel (P2-13), mirroring
 * `provider/routes.ts` -- same shape of store-plus-overridable-deps, same
 * `{400, 404}` status matrix, same masking rule for secrets on the way out.
 *
 * A duplicate name is deliberately a 400 rather than a 409: it is the request
 * body failing the store's uniqueness rule, and keeping the matrix to exactly
 * those two codes matches every other config route here, so Swift has one
 * error path to handle.
 *
 * The tools these servers contribute run unsandboxed, exactly like the
 * built-in ones -- `server.ts` merges them into the same set it wraps in
 * `withApproval`, so they pass the same gate. Nothing here bypasses that seam.
 */
export function buildMcpConfigRoutes(
  store: McpConfigStore,
  deps: Partial<McpConfigRouteDeps> = {},
): Route[] {
  const { probeMcpServer, envJson } = { ...defaultDeps, ...deps };

  return [
    {
      method: "GET",
      path: "/config/mcp",
      handler: () => {
        const resolved = resolveMcpServers(store, envJson);
        return Response.json({
          // "Configured" is explicit, never ambient: env-var servers are
          // listed (a dev can see what they inherited) but never presented as
          // the user's own saved config.
          configured: store.getStatus().mcpConfigured,
          source: resolved.source,
          servers: resolved.servers.map(maskServer),
        });
      },
    },
    {
      method: "POST",
      path: "/config/mcp",
      handler: async (req) => {
        const body = await req.json();
        try {
          // No stored record on a create, so nothing to resolve masks against.
          const created = store.addServer(candidateFrom(body, undefined));
          return Response.json({ server: maskServer(created) });
        } catch (error) {
          return badRequest(error);
        }
      },
    },
    {
      method: "POST",
      path: "/config/mcp/test",
      handler: async (req) => {
        const body = await req.json();
        let candidate: StoredMcpServer;
        try {
          // A candidate is probed as the saved server of the *same name* would
          // be -- otherwise "Test Connection" on an already-saved server would
          // submit masks and fail with an auth error that has nothing to do
          // with the user's config. An unsaved name resolves against nothing
          // and is probed exactly as submitted, which matters here more than
          // anywhere else: this endpoint *sends* the resolved secrets to
          // whatever endpoint the (unsaved, attacker-shaped) candidate names.
          const submittedName = (body as { name?: unknown } | null)?.name;
          const saved =
            typeof submittedName === "string" ? store.getServer(submittedName.trim()) : undefined;
          candidate = candidateFrom(body, saved);
        } catch (error) {
          return badRequest(error);
        }
        try {
          const result = await probeMcpServer(candidate);
          return Response.json({ success: true, tools: result.tools });
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          return Response.json({ success: false, error: message });
        }
      },
    },
    {
      method: "PUT",
      path: "/config/mcp/:name",
      handler: async (req) => {
        const name = serverNameFromPath(req);
        const body = await req.json();
        // Addressing an unknown server is the one 404 case; a bad body for an
        // existing one is a 400, so existence is checked first.
        const stored = store.getServer(name);
        if (!stored) {
          return Response.json({ error: `No MCP server named "${name}"` }, { status: 404 });
        }
        try {
          const updated = store.updateServer(name, candidateFrom(body, stored));
          return Response.json({ server: maskServer(updated) });
        } catch (error) {
          return badRequest(error);
        }
      },
    },
    {
      method: "DELETE",
      path: "/config/mcp/:name",
      handler: (req) => {
        const name = serverNameFromPath(req);
        if (!store.removeServer(name)) {
          return Response.json({ error: `No MCP server named "${name}"` }, { status: 404 });
        }
        return Response.json({ deleted: true });
      },
    },
  ];
}
