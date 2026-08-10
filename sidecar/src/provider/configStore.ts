import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";
import type { LLMProviderType } from "./types";

export interface StoredLLMConfig {
  type: LLMProviderType;
  baseUrl: string;
  apiKey: string;
  model: string;
}

export type WhisperMode = "local" | "remote";

export interface StoredWhisperConfig {
  mode: WhisperMode;
  /** Remote mode only. */
  baseUrl?: string;
  apiKey?: string;
  model?: string;
}

export interface ProviderConfigStatus {
  llmConfigured: boolean;
  whisperConfigured: boolean;
}

interface ProviderConfigFile {
  llm?: StoredLLMConfig;
  llmConfigured: boolean;
  whisper?: StoredWhisperConfig;
  whisperConfigured: boolean;
}

const EMPTY_FILE: ProviderConfigFile = {
  llmConfigured: false,
  whisperConfigured: false,
};

/**
 * Persists the user-configured LLM + Whisper provider settings the new
 * Settings UI and first-run onboarding wizard write, so the running sidecar
 * process (which already owns all AI-provider logic, per this repo's
 * existing split) knows which provider to route `/oneshot/ask`/`/agent/run`/
 * `/asr/transcribe` through -- see `provider/routes.ts` for the HTTP surface
 * Swift calls, and `registry.ts` for how a stored config becomes a live
 * client.
 *
 * "Configured" is deliberately a separate boolean per surface
 * (`llmConfigured`/`whisperConfigured`), not just "a config object is
 * present" -- it's only set `true` by an explicit `setLLMConfig`/
 * `setWhisperConfig` call, i.e. the user actually completed a save (for LLM,
 * that's downstream of a successful Test Connection + model pick in the UI;
 * for Whisper, an explicit choice of local-or-remote). This is what the
 * first-run wizard (`server.ts`'s `/config/status`) gates on -- an
 * env-based `DEEPSEEK_API_KEY` alone never flips `llmConfigured`, since the
 * whole point of this feature is a user-driven config experience rather
 * than an ambient default silently counting as "configured".
 *
 * Storage format: plain JSON on local disk, `chmod 600` (owner read/write
 * only) after every write. This *does* mean the API key sits in plaintext
 * on the local filesystem rather than in Keychain -- a real tradeoff,
 * documented rather than hidden. It was chosen because (a) the sidecar
 * already owns a local writable data directory storing other
 * locally-sensitive data in plaintext (the SQLite memory store has never
 * been encrypted either), so this doesn't lower the app's existing trust
 * bar, and (b) the alternative -- Keychain-backed storage on the Swift side,
 * threaded through env vars at sidecar-spawn time -- reintroduces exactly
 * the Swift/sidecar credential-plumbing coupling this rewrite deliberately
 * removed (see CLAUDE.md's "no ProviderVault" history) and would need
 * re-spawning the sidecar (or a live env-reload mechanism that doesn't
 * exist) every time the user changes a key, which the HTTP-endpoint
 * approach here avoids entirely. `chmod 600` is the mitigation actually
 * available at this layer.
 */
export class ProviderConfigStore {
  private readonly path: string;
  private file: ProviderConfigFile;

  constructor(path: string) {
    this.path = path;
    this.file = this.load();
  }

  private load(): ProviderConfigFile {
    if (!existsSync(this.path)) {
      return { ...EMPTY_FILE };
    }
    let raw: string;
    try {
      raw = readFileSync(this.path, "utf8");
    } catch {
      // Unreadable for a reason other than absence -- boot unconfigured
      // rather than bricking the sidecar.
      return { ...EMPTY_FILE };
    }
    // A genuinely empty (zero-length) file -- e.g. a crash-truncated write --
    // is not corruption to preserve; just boot cleanly unconfigured.
    if (raw.length === 0) {
      return { ...EMPTY_FILE };
    }
    try {
      const parsed = JSON.parse(raw) as Partial<ProviderConfigFile>;
      return {
        llm: parsed.llm,
        llmConfigured: parsed.llmConfigured === true,
        whisper: parsed.whisper,
        whisperConfigured: parsed.whisperConfigured === true,
      };
    } catch (err) {
      // Corrupt (non-empty, unparseable) config. Throwing here would brick
      // sidecar boot (the store is constructed in server.ts main() with no
      // try/catch), including transcribe-only users who never configured a
      // provider. Instead self-heal loudly: preserve the original bytes aside
      // as evidence, log, and start cleanly unconfigured so onboarding can
      // re-trigger.
      const corruptPath = `${this.path}.corrupt-${Date.now()}`;
      try {
        renameSync(this.path, corruptPath);
      } catch {
        // If we can't rename it aside, still don't block boot.
      }
      console.error(
        `[ProviderConfigStore] Corrupt provider config at ${this.path}; ` +
          `preserved original bytes to ${corruptPath} and starting ` +
          `unconfigured. Parse error: ${String(err)}`,
      );
      return { ...EMPTY_FILE };
    }
  }

  private persist(): void {
    const dir = dirname(this.path);
    if (dir && dir !== "." && !existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    const data = JSON.stringify(this.file, null, 2);
    // Atomic write: create a fresh temp file 0600 from the start (no
    // world-readable window on the plaintext API key), then atomically rename
    // it onto the destination so the config is only ever replaced whole and
    // the destination path is never observably truncated. A leftover temp is
    // cleaned up on failure.
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

  /**
   * Validate + normalize a provider baseUrl. Rejects empty/malformed values
   * and any non-http(s) scheme. Normalizes by stripping trailing slash(es) via
   * plain string trimming -- deliberately NOT `new URL().toString()`, which
   * re-appends a "/" to a root URL and would turn `https://api.deepseek.com/`
   * back into `https://api.deepseek.com/` instead of the desired
   * `https://api.deepseek.com`.
   */
  private normalizeBaseUrl(baseUrl: string): string {
    if (typeof baseUrl !== "string" || baseUrl.trim().length === 0) {
      throw new Error("baseUrl must be a non-empty http(s) URL");
    }
    const trimmed = baseUrl.trim();
    let parsed: URL;
    try {
      parsed = new URL(trimmed);
    } catch {
      throw new Error(`baseUrl is not a valid URL: ${baseUrl}`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error(
        `baseUrl must use http or https, got: ${parsed.protocol}`,
      );
    }
    return trimmed.replace(/\/+$/, "");
  }

  getStatus(): ProviderConfigStatus {
    return {
      llmConfigured: this.file.llmConfigured,
      whisperConfigured: this.file.whisperConfigured,
    };
  }

  getLLMConfig(): StoredLLMConfig | undefined {
    return this.file.llm;
  }

  setLLMConfig(config: StoredLLMConfig): void {
    const normalized: StoredLLMConfig = {
      ...config,
      baseUrl: this.normalizeBaseUrl(config.baseUrl),
    };
    this.file = { ...this.file, llm: normalized, llmConfigured: true };
    this.persist();
  }

  getWhisperConfig(): StoredWhisperConfig | undefined {
    return this.file.whisper;
  }

  setWhisperConfig(config: StoredWhisperConfig): void {
    // Local mode needs no baseUrl; remote mode's baseUrl is validated +
    // normalized the same way as the LLM config.
    const normalized: StoredWhisperConfig =
      config.mode === "remote" && config.baseUrl !== undefined
        ? { ...config, baseUrl: this.normalizeBaseUrl(config.baseUrl) }
        : { ...config };
    this.file = { ...this.file, whisper: normalized, whisperConfigured: true };
    this.persist();
  }
}
