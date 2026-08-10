/**
 * STAGE-1 (red) tests pinning bug P2 in `src/provider/configStore.ts`
 * (`ProviderConfigStore`). The store persists user LLM/Whisper provider
 * config (including plaintext API keys) to local disk. Four hardening gaps,
 * each with the desired corrected behavior Stage 3 must implement:
 *
 *  1. PERMISSIONS / NO 0644 WINDOW. The current `persist()` does
 *     `writeFileSync(path, data)` (creates the file 0666 & ~umask, i.e.
 *     typically 0644) and only THEN `chmodSync(path, 0o600)`. Between those
 *     two syscalls the API key sits world-readable. Desired: the bytes are
 *     written to a fresh temp file created with `{ mode: 0o600 }` from the
 *     start, then atomically `rename`d onto the destination -- so the path a
 *     reader sees is only ever the finished 0600 file, never a broad-mode
 *     one.
 *
 *  2. ATOMIC WRITE. The current in-place `writeFileSync` truncates the real
 *     file first; a crash mid-write leaves a truncated/zero-length config and
 *     the key/config is lost. Desired: temp-file + atomic `rename`, so the
 *     destination is only ever replaced whole (never observably truncated),
 *     and no temp artifact is left behind after a successful save.
 *
 *     Discriminator used here: an in-place `writeFileSync` reuses the
 *     destination inode across rewrites (open + O_TRUNC), whereas a
 *     temp-file+rename swaps in a brand-new inode each save. So "inode
 *     changes when re-saving over an existing file" deterministically proves
 *     the atomic-rename strategy without needing to crash the process.
 *
 *  3. baseUrl VALIDATION + NORMALIZATION. `baseUrl` is currently stored with
 *     zero validation. Desired: a non-http(s) / malformed / empty baseUrl is
 *     rejected (the setter throws) rather than silently persisted; a valid
 *     http/https baseUrl is normalized on save by stripping trailing
 *     slash(es).
 *
 *  4. CORRUPT-FILE LOAD. The current `load()` catches any parse error and
 *     silently returns EMPTY_FILE, so a corrupt config reads back as
 *     "never configured" -- losing the fact that config existed and masking
 *     the corruption. The store is constructed at sidecar startup (server.ts
 *     main(), no surrounding try/catch), so THROWING on a corrupt file would
 *     brick the entire sidecar boot -- including transcribe-only users who
 *     never configured a provider. Desired: self-heal loudly instead -- rename
 *     the corrupt file aside (a `*.corrupt*` sibling, preserving the bytes as
 *     evidence), log an error, and start cleanly unconfigured so the sidecar
 *     still boots and onboarding can re-trigger. Corruption is surfaced (not
 *     silently swallowed), but boot is never blocked. A genuinely absent file
 *     still starts cleanly unconfigured (unchanged).
 *
 * These are written against the DESIRED corrected API and are expected to be
 * RED against the current implementation.
 */
import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { ProviderConfigStore } from "../../src/provider/configStore";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "opentype-provider-config-hardening-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const validLLM = (over: Record<string, unknown> = {}) => ({
  type: "openai-compatible" as const,
  baseUrl: "https://api.deepseek.com",
  apiKey: "sk-secret",
  model: "deepseek-chat",
  ...over,
});

describe("ProviderConfigStore hardening P2", () => {
  describe("1. owner-only permissions with no 0644 window", () => {
    test("the persisted file's final mode is exactly 0600 (no group/other bits)", () => {
      const path = join(dir, "provider-config.json");
      const store = new ProviderConfigStore(path);
      store.setLLMConfig(validLLM());

      const mode = statSync(path).mode & 0o777;
      expect(mode).toBe(0o600);
    });

    test("re-saving swaps in a NEW inode (temp-file+rename), so the path is never written in-place through a broad-mode window", () => {
      const path = join(dir, "provider-config.json");
      const store = new ProviderConfigStore(path);

      store.setLLMConfig(validLLM({ apiKey: "sk-first" }));
      const firstInode = statSync(path).ino;
      const firstMode = statSync(path).mode & 0o777;
      expect(firstMode).toBe(0o600);

      store.setLLMConfig(validLLM({ apiKey: "sk-second" }));
      const secondInode = statSync(path).ino;
      const secondMode = statSync(path).mode & 0o777;

      // In-place writeFileSync keeps the same inode (open + O_TRUNC); an
      // atomic temp-file+rename replaces it with a fresh inode. This is the
      // deterministic proof that the destination path is only ever the
      // finished 0600 temp being renamed in, never a direct broad-mode write.
      expect(secondInode).not.toBe(firstInode);
      expect(secondMode).toBe(0o600);
    });
  });

  describe("2. atomic write (no leftover temp, whole-file replace)", () => {
    test("leaves no temp/partial artifact in the directory after a successful save", () => {
      const path = join(dir, "provider-config.json");
      const store = new ProviderConfigStore(path);
      store.setLLMConfig(validLLM());

      const entries = readdirSync(dir);
      // Only the finished config file should remain; a temp-file+rename
      // implementation must clean up / rename away any `*.tmp` scratch file.
      expect(entries).toEqual([basename(path)]);
    });

    test("the destination file is always complete, valid JSON after a save (never truncated/zero-length)", () => {
      const path = join(dir, "provider-config.json");
      const store = new ProviderConfigStore(path);
      store.setLLMConfig(validLLM({ apiKey: "sk-secret" }));

      const raw = readFileSync(path, "utf8");
      expect(raw.length).toBeGreaterThan(0);
      const parsed = JSON.parse(raw);
      expect(parsed.llm.apiKey).toBe("sk-secret");
      expect(parsed.llmConfigured).toBe(true);
    });
  });

  describe("3. baseUrl validation + normalization", () => {
    test("rejects a malformed baseUrl (not a URL)", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      expect(() => store.setLLMConfig(validLLM({ baseUrl: "not a url" }))).toThrow();
    });

    test("rejects a non-http(s) scheme (ftp://)", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      expect(() => store.setLLMConfig(validLLM({ baseUrl: "ftp://example.com" }))).toThrow();
    });

    test("rejects an empty baseUrl", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      expect(() => store.setLLMConfig(validLLM({ baseUrl: "" }))).toThrow();
    });

    test("a rejected save does not persist anything to disk", () => {
      const path = join(dir, "c.json");
      const store = new ProviderConfigStore(path);
      expect(() => store.setLLMConfig(validLLM({ baseUrl: "not a url" }))).toThrow();
      expect(existsSync(path)).toBe(false);
      expect(store.getStatus().llmConfigured).toBe(false);
    });

    test("normalizes a valid https baseUrl by stripping the trailing slash on save", () => {
      const path = join(dir, "c.json");
      const store = new ProviderConfigStore(path);
      store.setLLMConfig(validLLM({ baseUrl: "https://api.deepseek.com/" }));

      expect(store.getLLMConfig()?.baseUrl).toBe("https://api.deepseek.com");
      const persisted = JSON.parse(readFileSync(path, "utf8"));
      expect(persisted.llm.baseUrl).toBe("https://api.deepseek.com");
    });

    test("normalization preserves a base path, only stripping the trailing slash", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      store.setLLMConfig(validLLM({ baseUrl: "https://host.example/v1/" }));
      expect(store.getLLMConfig()?.baseUrl).toBe("https://host.example/v1");
    });

    test("a clean baseUrl (no trailing slash) is stored unchanged", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      store.setLLMConfig(validLLM({ baseUrl: "https://api.deepseek.com" }));
      expect(store.getLLMConfig()?.baseUrl).toBe("https://api.deepseek.com");
    });

    test("Whisper local mode (no baseUrl) is accepted", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      expect(() => store.setWhisperConfig({ mode: "local" })).not.toThrow();
      expect(store.getStatus().whisperConfigured).toBe(true);
    });

    test("Whisper remote mode rejects a malformed baseUrl", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      expect(() =>
        store.setWhisperConfig({ mode: "remote", baseUrl: "not a url", apiKey: "sk", model: "whisper-1" })
      ).toThrow();
    });

    test("Whisper remote mode normalizes a trailing-slash baseUrl", () => {
      const store = new ProviderConfigStore(join(dir, "c.json"));
      store.setWhisperConfig({
        mode: "remote",
        baseUrl: "https://api.openai.com/v1/",
        apiKey: "sk-openai",
        model: "whisper-1",
      });
      expect(store.getWhisperConfig()?.baseUrl).toBe("https://api.openai.com/v1");
    });
  });

  describe("4. corrupt-file load self-heals (preserve aside, boot unconfigured)", () => {
    test("recovers from unparseable garbage: preserves the bytes aside, boots unconfigured, does not throw", () => {
      const path = join(dir, "provider-config.json");
      const garbage = "{ this is not valid json ";
      writeFileSync(path, garbage, "utf8");

      let store: ProviderConfigStore | undefined;
      // Must NOT throw -- throwing here would brick sidecar boot.
      expect(() => {
        store = new ProviderConfigStore(path);
      }).not.toThrow();

      // Corruption surfaced, not masked: the original bytes are preserved to a
      // `*.corrupt*` sibling so the evidence isn't silently lost.
      const siblings = readdirSync(dir).filter(
        (f) => f !== basename(path) && f.includes("corrupt")
      );
      expect(siblings.length).toBeGreaterThanOrEqual(1);
      expect(readFileSync(join(dir, siblings[0]!), "utf8")).toBe(garbage);

      // The live config path no longer holds the garbage.
      if (existsSync(path)) {
        expect(readFileSync(path, "utf8")).not.toBe(garbage);
      }

      // Sidecar still boots: status is cleanly unconfigured so onboarding can
      // re-trigger and the user can reconfigure.
      expect(store!.getStatus()).toEqual({
        llmConfigured: false,
        whisperConfigured: false,
      });
    });

    test("recovers from a zero-length (crash-truncated) config: boots unconfigured, does not throw", () => {
      const path = join(dir, "provider-config.json");
      writeFileSync(path, "", "utf8");

      let store: ProviderConfigStore | undefined;
      expect(() => {
        store = new ProviderConfigStore(path);
      }).not.toThrow();
      expect(store!.getStatus()).toEqual({
        llmConfigured: false,
        whisperConfigured: false,
      });
    });

    test("an absent file still starts cleanly unconfigured (no false-positive throw)", () => {
      const path = join(dir, "does-not-exist.json");
      let store: ProviderConfigStore;
      expect(() => {
        store = new ProviderConfigStore(path);
        return store;
      }).not.toThrow();
      expect(new ProviderConfigStore(path).getStatus()).toEqual({
        llmConfigured: false,
        whisperConfigured: false,
      });
    });
  });
});
