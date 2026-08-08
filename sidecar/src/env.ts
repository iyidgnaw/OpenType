export interface SidecarEnv {
  socketPath: string;
  deepSeekApiKey: string;
  deepSeekModel: string;
  deepSeekBaseUrl: string;
  dbPath: string;
}

export function loadEnv(source: NodeJS.ProcessEnv = process.env): SidecarEnv {
  const socketPath =
    source.OPENTYPE_SIDECAR_SOCKET ?? "/tmp/opentype-sidecar-dev.sock";
  const deepSeekApiKey = source.DEEPSEEK_API_KEY ?? "";
  const deepSeekModel = source.DEEPSEEK_MODEL ?? "deepseek-v4-flash";
  const deepSeekBaseUrl = source.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
  const dbPath =
    source.OPENTYPE_SIDECAR_DB_PATH ?? "sidecar/.data/opentype.sqlite3";

  return { socketPath, deepSeekApiKey, deepSeekModel, deepSeekBaseUrl, dbPath };
}
