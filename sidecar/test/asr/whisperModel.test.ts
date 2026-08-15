/**
 * STAGE-1 (red) tests for §E-4 of
 * `docs/superpowers/specs/2026-08-15-product-batch-plan.md`: the Whisper model
 * becomes configurable, and a saved choice beats `OPENTYPE_WHISPER_MODEL`.
 *
 * ---------------------------------------------------------------------------
 * The problem, in the review's own words (§3)
 * ---------------------------------------------------------------------------
 *
 * 「`serve.py:41` 的 `OPENTYPE_WHISPER_MODEL` 是唯一入口，打包版用户改不到——
 * 这和 MCP 服务器当初的问题一字不差，而 MCP 那条已经在 P2-13 解决了，这条没有。」
 *
 * So this is not a new pattern: it is `McpConfigStore`/`resolveMcpServers`
 * applied to one string. Everything below mirrors that precedent on purpose —
 * saved wins entirely, an ambient env var is a zero-config dev fallback and
 * **never** reports as configured, and the resolution is a pure function tested
 * apart from both the store and the routes.
 *
 * ---------------------------------------------------------------------------
 * The contract stage 3 must implement
 * ---------------------------------------------------------------------------
 *
 * `sidecar/src/asr/whisperModel.ts`:
 *
 *   export const DEFAULT_WHISPER_MODEL = "mlx-community/whisper-small-mlx";
 *
 *   export interface WhisperModelPreset {
 *     id: string;                        // HF repo id
 *     approximateDownloadBytes: number;  // for 「约 460 MB」
 *   }
 *   export const WHISPER_MODEL_PRESETS: readonly WhisperModelPreset[];
 *
 *   export type WhisperModelSource = "saved" | "env" | "default";
 *   export interface ResolvedWhisperModel {
 *     model: string;
 *     source: WhisperModelSource;
 *     configured: boolean;   // true only for "saved"
 *   }
 *   export function resolveWhisperModel(
 *     saved: string | undefined,
 *     envValue: string | undefined
 *   ): ResolvedWhisperModel;
 *
 * `sidecar/src/provider/configStore.ts` (the same store, the same file on disk —
 * 「复用 `ProviderConfigStore` 同目录的写法，**不新造存储策略**」):
 *
 *   getWhisperModel(): string | undefined;
 *   setWhisperModel(model: string): void;
 *
 * `sidecar/src/asr/whisperModelRoutes.ts`:
 *
 *   export function buildWhisperModelRoutes(
 *     store: ProviderConfigStore,
 *     options?: { envValue?: string }
 *   ): Route[];   // GET + PUT /config/whisper-model
 *
 * Four decisions this file makes on stage 3's behalf, deliberately:
 *
 * 1. **The presets carry no display copy.** `{id, approximateDownloadBytes}`
 *    and nothing else; Swift renders 「小 / 中 / 大」 and the size string. Every
 *    other config endpoint in this sidecar returns data rather than labels, and
 *    §F (界面语言跟随系统) is about to audit every user-visible string in the
 *    product — a Chinese label shipped from the sidecar would be outside that
 *    audit by construction.
 * 2. **The presets are a menu, not an allowlist.** Any non-empty string saves.
 *    `OPENTYPE_WHISPER_MODEL` accepts any HF repo id today, and shipping a
 *    picker that *removes* the ability to point at a fine-tuned model would be
 *    a downgrade dressed as a feature.
 * 3. **`setWhisperModel` must not flip `whisperConfigured`.** That flag gates
 *    the first-run onboarding wizard (`GET /config/status`'s `ready`), and it
 *    answers 「用户选过本地还是远程了吗」. Picking a model size is a different
 *    question; conflating them would let a model choice dismiss the wizard.
 * 4. **`PUT` reports `restartRequired: true` rather than restarting the child.**
 *    The spec allows either. Restarting mid-flight means killing a python
 *    process that may be blocking a queued transcription and re-downloading up
 *    to 1.5 GB before anything works again — a bigger, separately reviewable
 *    change than this batch item. Saying it, as the MCP panel already says
 *    「下次启动生效」, is 取简单可靠的那个.
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRouter } from "../../src/router";
import { ProviderConfigStore } from "../../src/provider/configStore";
import {
  DEFAULT_WHISPER_MODEL,
  WHISPER_MODEL_PRESETS,
  resolveWhisperModel,
} from "../../src/asr/whisperModel";
import { buildWhisperModelRoutes } from "../../src/asr/whisperModelRoutes";

const SMALL = "mlx-community/whisper-small-mlx";
const MEDIUM = "mlx-community/whisper-medium-mlx";
const LARGE = "mlx-community/whisper-large-v3-mlx";

let dir: string;
let configPath: string;
let store: ProviderConfigStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-whisper-model-"));
  configPath = join(dir, "provider-config.json");
  store = new ProviderConfigStore(configPath);
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function makeApp(envValue?: string) {
  return createRouter(buildWhisperModelRoutes(store, { envValue }));
}

async function call(
  app: ReturnType<typeof createRouter>,
  method: string,
  body?: unknown
) {
  const response = await app(
    new Request("http://localhost/config/whisper-model", {
      method,
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
  );
  return { status: response.status, json: (await response.json()) as Record<string, any> };
}

// ---------------------------------------------------------------------------
// 1. The presets
// ---------------------------------------------------------------------------

describe("WHISPER_MODEL_PRESETS", () => {
  test("offers exactly the three the spec names, smallest first", () => {
    expect(WHISPER_MODEL_PRESETS.map((preset) => preset.id)).toEqual([
      SMALL,
      MEDIUM,
      LARGE,
    ]);
  });

  test("the default is the small model, which is preset[0]", () => {
    expect(DEFAULT_WHISPER_MODEL).toBe(SMALL);
    expect(WHISPER_MODEL_PRESETS[0]!.id).toBe(DEFAULT_WHISPER_MODEL);
  });

  test("each carries a download size, strictly increasing", () => {
    // The size is the entire reason a picker beats a text field: 「约 460 MB」 vs
    // 「约 3 GB」 is the decision the user is actually making, and it is the
    // number §E-3's banner quotes back at them during the download.
    const sizes = WHISPER_MODEL_PRESETS.map((preset) => preset.approximateDownloadBytes);
    for (const size of sizes) {
      expect(typeof size).toBe("number");
      expect(size).toBeGreaterThan(0);
    }
    expect([...sizes].sort((a, b) => a - b)).toEqual(sizes);
  });

  test("carries no display copy", () => {
    // See header decision 1: §F is about to audit every user-visible string,
    // and a label shipped from here would be outside that audit by
    // construction.
    for (const preset of WHISPER_MODEL_PRESETS) {
      expect(Object.keys(preset).sort()).toEqual(["approximateDownloadBytes", "id"]);
    }
  });

  test("the small preset is still the model Cantonese was measured against", () => {
    // TRIPWIRE, not a duplicate assertion. `TranscriptionLanguage.cantonese`
    // maps to "zh" and NOT to Whisper's own "yue", because whisper-small's
    // checkpoint reports n_vocab == 51865 -> num_languages == 99, and `yue` is
    // the 100th key of Whisper's LANGUAGES table: mlx_whisper raises
    // `ValueError: tuple.index(x): x not in tuple` and serve.py answers HTTP
    // 500, i.e. EVERY Cantonese transcription fails. Measured 2026-08-15; see
    // the comment on that enum case in `Sources/OpenType/Models.swift`.
    //
    // On large-v3 `yue` works. So the mapping is only correct relative to this
    // constant, and this batch is the one that makes the constant movable.
    // If you are changing DEFAULT_WHISPER_MODEL, re-measure Cantonese first and
    // update Models.swift in the same change.
    expect(DEFAULT_WHISPER_MODEL).toBe("mlx-community/whisper-small-mlx");
  });
});

// ---------------------------------------------------------------------------
// 2. resolveWhisperModel — saved beats env, exactly like MCP
// ---------------------------------------------------------------------------

describe("resolveWhisperModel", () => {
  test("nothing saved, nothing in the environment: the default, unconfigured", () => {
    expect(resolveWhisperModel(undefined, undefined)).toEqual({
      model: DEFAULT_WHISPER_MODEL,
      source: "default",
      configured: false,
    });
  });

  test("an environment variable alone is used but never counts as configured", () => {
    // The mirror of `resolveMcpServers`: 「一个 ambient env var 单独存在时永远不报告
    // 为 configured」. It is a zero-config dev fallback, not a user decision, and
    // `configured` is what the UI renders as 「你选过了」.
    expect(resolveWhisperModel(undefined, LARGE)).toEqual({
      model: LARGE,
      source: "env",
      configured: false,
    });
  });

  test("a saved model wins over the environment variable", () => {
    // THE precedence assertion, 「与 MCP 的 saved-beats-env 精确一致」.
    expect(resolveWhisperModel(MEDIUM, LARGE)).toEqual({
      model: MEDIUM,
      source: "saved",
      configured: true,
    });
  });

  test("a saved model with no environment variable is still saved/configured", () => {
    expect(resolveWhisperModel(MEDIUM, undefined)).toEqual({
      model: MEDIUM,
      source: "saved",
      configured: true,
    });
  });

  test("a saved model that happens to equal the default is still saved", () => {
    // 「我特地选了 small」 and 「我从没选过」 are different states: the first must not
    // be silently re-derived from the environment on the next launch.
    expect(resolveWhisperModel(SMALL, LARGE)).toEqual({
      model: SMALL,
      source: "saved",
      configured: true,
    });
  });

  test("a non-preset repo id resolves unchanged", () => {
    // The presets are a menu, not an allowlist — see header decision 2.
    expect(resolveWhisperModel("mlx-community/whisper-tiny-mlx", undefined)).toEqual({
      model: "mlx-community/whisper-tiny-mlx",
      source: "saved",
      configured: true,
    });
  });

  test("blank values on either side are not a model", () => {
    // `OPENTYPE_WHISPER_MODEL=""` is how a shell spells 「没设」, and passing "" to
    // mlx_whisper is a load failure rather than a default.
    expect(resolveWhisperModel(undefined, "")).toEqual({
      model: DEFAULT_WHISPER_MODEL,
      source: "default",
      configured: false,
    });
    expect(resolveWhisperModel("", undefined)).toEqual({
      model: DEFAULT_WHISPER_MODEL,
      source: "default",
      configured: false,
    });
    expect(resolveWhisperModel("   ", "  ")).toEqual({
      model: DEFAULT_WHISPER_MODEL,
      source: "default",
      configured: false,
    });
  });

  test("surrounding whitespace is trimmed off an environment value", () => {
    expect(resolveWhisperModel(undefined, `  ${LARGE}\n`)).toEqual({
      model: LARGE,
      source: "env",
      configured: false,
    });
  });
});

// ---------------------------------------------------------------------------
// 3. Storage — the same file, the same conventions
// ---------------------------------------------------------------------------

describe("ProviderConfigStore whisper model", () => {
  test("is undefined until something saves one", () => {
    expect(store.getWhisperModel()).toBeUndefined();
  });

  test("persists across a reopen of the same file", () => {
    store.setWhisperModel(MEDIUM);

    expect(new ProviderConfigStore(configPath).getWhisperModel()).toBe(MEDIUM);
  });

  test("does not flip whisperConfigured", () => {
    // See header decision 3: `whisperConfigured` gates the onboarding wizard and
    // answers 「本地还是远程」. A model size is not an answer to that question.
    store.setWhisperModel(LARGE);

    expect(store.getStatus().whisperConfigured).toBe(false);
    expect(store.getWhisperConfig()).toBeUndefined();
  });

  test("does not disturb the remote-Whisper config, or get disturbed by it", () => {
    // `StoredWhisperConfig.model` already exists and means the REMOTE model id.
    // These are two different fields with the same word in their name, which is
    // exactly the pair that ends up sharing one slot by accident.
    store.setWhisperConfig({
      mode: "remote",
      baseUrl: "https://api.openai.com/v1",
      apiKey: "sk-x",
      model: "whisper-1",
    });
    store.setWhisperModel(MEDIUM);

    const reopened = new ProviderConfigStore(configPath);
    expect(reopened.getWhisperModel()).toBe(MEDIUM);
    expect(reopened.getWhisperConfig()?.model).toBe("whisper-1");
    expect(reopened.getStatus().whisperConfigured).toBe(true);
  });

  test("does not disturb the LLM config", () => {
    store.setLLMConfig({
      type: "openai-compatible",
      baseUrl: "https://api.deepseek.com",
      apiKey: "sk-secret",
      model: "deepseek-chat",
    });
    store.setWhisperModel(LARGE);

    const reopened = new ProviderConfigStore(configPath);
    expect(reopened.getLLMConfig()?.apiKey).toBe("sk-secret");
    expect(reopened.getStatus().llmConfigured).toBe(true);
    expect(reopened.getWhisperModel()).toBe(LARGE);
  });

  test("writes through the store's existing 0600 path", () => {
    // 「不新造存储策略」 — same file, same atomic-rename-over-a-0600-temp write.
    // A second write path next to a plaintext API key is how the key ends up
    // world-readable for a window.
    store.setWhisperModel(MEDIUM);

    expect(statSync(configPath).mode & 0o777).toBe(0o600);
    expect(JSON.parse(readFileSync(configPath, "utf8"))).toMatchObject({
      whisperModel: MEDIUM,
    });
  });

  test("survives a config file written before this field existed", () => {
    // Every user upgrading into this batch has one.
    store.setLLMConfig({
      type: "anthropic",
      baseUrl: "https://api.anthropic.com",
      apiKey: "sk-ant-x",
      model: "claude-sonnet-4-5-20250929",
    });

    const reopened = new ProviderConfigStore(configPath);
    expect(reopened.getWhisperModel()).toBeUndefined();
    expect(reopened.getStatus().llmConfigured).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// 4. GET / PUT /config/whisper-model
// ---------------------------------------------------------------------------

describe("GET /config/whisper-model", () => {
  test("reports the default and the presets when nothing is set", async () => {
    const { status, json } = await call(makeApp(), "GET");

    expect(status).toBe(200);
    expect(json.configured).toBe(false);
    expect(json.model).toBe(DEFAULT_WHISPER_MODEL);
    expect(json.source).toBe("default");
    expect(json.presets).toEqual([...WHISPER_MODEL_PRESETS]);
  });

  test("reports an environment override as source:env, configured:false", async () => {
    const { json } = await call(makeApp(LARGE), "GET");

    expect(json).toMatchObject({ model: LARGE, source: "env", configured: false });
  });

  test("reports a saved model over an environment override", async () => {
    // Saved-beats-env asserted at the HTTP layer too, not only in the pure
    // function: this is the response the Settings panel actually renders, and a
    // panel that shows the env value while the child runs the saved one is the
    // same silent mismatch this section exists to remove.
    store.setWhisperModel(MEDIUM);

    const { json } = await call(makeApp(LARGE), "GET");

    expect(json).toMatchObject({ model: MEDIUM, source: "saved", configured: true });
  });

  test("reads the store per request rather than snapshotting it at build time", async () => {
    const app = makeApp();
    expect((await call(app, "GET")).json.model).toBe(DEFAULT_WHISPER_MODEL);

    store.setWhisperModel(LARGE);

    expect((await call(app, "GET")).json.model).toBe(LARGE);
  });
});

describe("PUT /config/whisper-model", () => {
  test("saves a preset and says a restart is needed", async () => {
    const app = makeApp();

    const { status, json } = await call(app, "PUT", { model: MEDIUM });

    expect(status).toBe(200);
    expect(json).toMatchObject({
      configured: true,
      model: MEDIUM,
      source: "saved",
      restartRequired: true,
    });
    expect(store.getWhisperModel()).toBe(MEDIUM);
  });

  test("the saved value is what a following GET reports", async () => {
    const app = makeApp(LARGE);

    await call(app, "PUT", { model: SMALL });

    expect((await call(app, "GET")).json).toMatchObject({
      model: SMALL,
      source: "saved",
      configured: true,
    });
  });

  test("accepts a repo id that is not one of the presets", async () => {
    const app = makeApp();

    const { status, json } = await call(app, "PUT", {
      model: "someone/whisper-cantonese-finetune-mlx",
    });

    expect(status).toBe(200);
    expect(json.model).toBe("someone/whisper-cantonese-finetune-mlx");
  });

  test("trims surrounding whitespace before saving", async () => {
    const app = makeApp();

    await call(app, "PUT", { model: `  ${LARGE}  ` });

    expect(store.getWhisperModel()).toBe(LARGE);
  });

  test("rejects a missing model with 400 and saves nothing", async () => {
    const app = makeApp();

    const { status, json } = await call(app, "PUT", {});

    expect(status).toBe(400);
    expect(json.error).toBeTruthy();
    expect(store.getWhisperModel()).toBeUndefined();
  });

  test("rejects an empty or blank model with 400", async () => {
    const app = makeApp();

    expect((await call(app, "PUT", { model: "" })).status).toBe(400);
    expect((await call(app, "PUT", { model: "   " })).status).toBe(400);
    expect(store.getWhisperModel()).toBeUndefined();
  });

  test("rejects a non-string model with 400", async () => {
    const app = makeApp();

    const { status } = await call(app, "PUT", { model: 3 });

    expect(status).toBe(400);
    expect(store.getWhisperModel()).toBeUndefined();
  });

  test("is idempotent", async () => {
    const app = makeApp();

    await call(app, "PUT", { model: MEDIUM });
    const { status, json } = await call(app, "PUT", { model: MEDIUM });

    expect(status).toBe(200);
    expect(json.model).toBe(MEDIUM);
    expect(store.getWhisperModel()).toBe(MEDIUM);
  });
});

describe("route registration", () => {
  test("registers exactly GET and PUT on /config/whisper-model", () => {
    const routes = buildWhisperModelRoutes(store, {});

    expect(routes.map((route) => `${route.method} ${route.path}`).sort()).toEqual([
      "GET /config/whisper-model",
      "PUT /config/whisper-model",
    ]);
  });
});

// ---------------------------------------------------------------------------
// 5. Wiring: without this, the whole endpoint configures nothing
// ---------------------------------------------------------------------------

describe("server.ts wires the resolved model into the whisper child", () => {
  test("resolves the model and passes it down as OPENTYPE_WHISPER_MODEL", () => {
    // `main()` is not exported and never will be testable — the same reason
    // `src/lifecycle.ts` exists, and the same guard `mcpBootResilience.test.ts`
    // uses for boot ordering. Everything above proves the seam is correct; this
    // proves it is connected. `WhisperClient` merges `extraEnv` into the
    // spawned process's environment, and `serve.py` reads
    // `OPENTYPE_WHISPER_MODEL` from there — so handing it the RESOLVED value is
    // precisely what makes 「保存的配置优先」 true at the only layer that matters,
    // the one that decides which weights get downloaded.
    const source = readFileSync(join(import.meta.dir, "..", "..", "src", "server.ts"), "utf8");

    expect(source).toMatch(/resolveWhisperModel\s*\(/);
    expect(source).toMatch(/OPENTYPE_WHISPER_MODEL/);
    expect(source).toMatch(/extraEnv/);
  });

  test("serves both new endpoints", () => {
    const source = readFileSync(join(import.meta.dir, "..", "..", "src", "server.ts"), "utf8");

    expect(source).toMatch(/buildWhisperModelRoutes/);
    expect(source).toMatch(/buildAsrStatusRoutes/);
  });
});
