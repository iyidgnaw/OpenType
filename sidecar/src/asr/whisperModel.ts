/**
 * Which local speech model to load, and where that choice came from.
 *
 * Until §E the only way to change it was `OPENTYPE_WHISPER_MODEL`, an
 * environment variable a packaged-app user cannot set — word for word the
 * problem MCP servers had before P2-13, and this is that fix applied to one
 * string. The precedent is followed on purpose: a saved choice wins entirely,
 * an ambient environment variable is a zero-config developer fallback that
 * **never** reports as configured, and the resolution is a pure function tested
 * apart from both the store and the routes.
 */

export const DEFAULT_WHISPER_MODEL = "mlx-community/whisper-small-mlx";

export interface WhisperModelPreset {
  /** Hugging Face repo id, passed to `mlx_whisper` as `path_or_hf_repo`. */
  id: string;
  /**
   * Roughly what the first launch has to download. The size is the entire
   * reason a picker beats a text field — 「约 460 MB」 against 「约 3 GB」 is the
   * decision the user is actually making, and it is the number the download
   * banner quotes back at them while they wait.
   */
  approximateDownloadBytes: number;
}

/**
 * The menu, smallest first. Carries no display copy: Swift renders the names
 * and sizes, because every other config endpoint here returns data rather than
 * labels, and a Chinese string shipped from the sidecar would sit outside the
 * interface-language work by construction.
 *
 * A menu, **not an allowlist** — `resolveWhisperModel` and the routes accept any
 * non-empty repo id. `OPENTYPE_WHISPER_MODEL` has always taken one, and
 * shipping a picker that removed the ability to point at a fine-tune would be a
 * downgrade dressed as a feature.
 */
export const WHISPER_MODEL_PRESETS: readonly WhisperModelPreset[] = [
  // The default, and the model Cantonese was measured against: whisper-small
  // rejects `language="yue"` because that key is the hundredth in Whisper's
  // table and this checkpoint's tokenizer knows ninety-nine, which is why
  // `TranscriptionLanguage.cantonese` maps to `"zh"`. Changing which model
  // ships by default obliges re-measuring that — on large-v3 `yue` works.
  { id: DEFAULT_WHISPER_MODEL, approximateDownloadBytes: 483_000_000 },
  { id: "mlx-community/whisper-medium-mlx", approximateDownloadBytes: 1_530_000_000 },
  { id: "mlx-community/whisper-large-v3-mlx", approximateDownloadBytes: 3_090_000_000 },
];

export type WhisperModelSource = "saved" | "env" | "default";

export interface ResolvedWhisperModel {
  model: string;
  source: WhisperModelSource;
  /** True only for `"saved"` — an ambient environment variable is not a choice. */
  configured: boolean;
}

function usable(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

/**
 * Saved beats environment beats default — the same precedence
 * `resolveMcpServers` uses, and for the same reason: an environment variable
 * the user never typed is a developer convenience, not a decision they made.
 */
export function resolveWhisperModel(
  saved: string | undefined,
  envValue: string | undefined
): ResolvedWhisperModel {
  const savedModel = usable(saved);
  if (savedModel) {
    return { model: savedModel, source: "saved", configured: true };
  }

  const envModel = usable(envValue);
  if (envModel) {
    return { model: envModel, source: "env", configured: false };
  }

  return { model: DEFAULT_WHISPER_MODEL, source: "default", configured: false };
}
