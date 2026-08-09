import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
    try {
      const raw = readFileSync(this.path, "utf8");
      const parsed = JSON.parse(raw) as Partial<ProviderConfigFile>;
      return {
        llm: parsed.llm,
        llmConfigured: parsed.llmConfigured === true,
        whisper: parsed.whisper,
        whisperConfigured: parsed.whisperConfigured === true,
      };
    } catch {
      return { ...EMPTY_FILE };
    }
  }

  private persist(): void {
    const dir = dirname(this.path);
    if (dir && dir !== "." && !existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    writeFileSync(this.path, JSON.stringify(this.file, null, 2), "utf8");
    chmodSync(this.path, 0o600);
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
    this.file = { ...this.file, llm: config, llmConfigured: true };
    this.persist();
  }

  getWhisperConfig(): StoredWhisperConfig | undefined {
    return this.file.whisper;
  }

  setWhisperConfig(config: StoredWhisperConfig): void {
    this.file = { ...this.file, whisper: config, whisperConfigured: true };
    this.persist();
  }
}
