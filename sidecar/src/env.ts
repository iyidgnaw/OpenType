export interface SidecarEnv {
  socketPath: string;
  deepSeekApiKey: string;
  deepSeekModel: string;
  deepSeekBaseUrl: string;
  dbPath: string;
  contextLogPath: string;
}

export function loadEnv(source: NodeJS.ProcessEnv = process.env): SidecarEnv {
  const socketPath =
    source.OPENTYPE_SIDECAR_SOCKET ?? "/tmp/opentype-sidecar-dev.sock";
  const deepSeekApiKey = source.DEEPSEEK_API_KEY ?? "";
  const deepSeekModel = source.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
  const deepSeekBaseUrl = source.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
  const dbPath =
    source.OPENTYPE_SIDECAR_DB_PATH ?? "sidecar/.data/opentype.sqlite3";
  // Proof-of-context-usage log (see `oneshot/contextDebugLog.ts`): follows
  // the same env-var-override-with-dev-default convention as `dbPath`
  // above. `SidecarClient.swift` sets `OPENTYPE_CONTEXT_LOG_PATH` alongside
  // `OPENTYPE_SIDECAR_SOCKET`/`OPENTYPE_SIDECAR_DB_PATH` for real app runs.
  const contextLogPath =
    source.OPENTYPE_CONTEXT_LOG_PATH ?? "sidecar/.data/context-debug.log";

  return { socketPath, deepSeekApiKey, deepSeekModel, deepSeekBaseUrl, dbPath, contextLogPath };
}
