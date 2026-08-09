import type { Route } from "../router";

interface TranscribeRequestBody {
  audioBase64?: string;
}

function decodeBase64(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch {
    return null;
  }
}

async function handleTranscribe(
  req: Request,
  transcribe: (audio: Uint8Array) => Promise<string>
): Promise<Response> {
  const body = (await req.json()) as TranscribeRequestBody;
  const audioBase64 = body.audioBase64 ?? "";
  if (!audioBase64) {
    return Response.json({ error: "audioBase64 is required" }, { status: 400 });
  }
  const audio = decodeBase64(audioBase64);
  if (!audio) {
    return Response.json({ error: "audioBase64 is not valid base64" }, { status: 400 });
  }

  try {
    const text = await transcribe(audio);
    return Response.json({ text });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return Response.json({ error: message }, { status: 502 });
  }
}

/**
 * Local ASR route, backed by the MLX-Whisper python process managed by
 * `WhisperClient`. Takes a plain `transcribe` function rather than a
 * `WhisperClient` instance so it stays testable the same way
 * `buildOneShotRoutes`/`buildAgentRoutes` take a bare `chat` function instead
 * of a concrete client.
 */
export function buildAsrRoutes(transcribe: (audio: Uint8Array) => Promise<string>): Route[] {
  return [
    {
      method: "POST",
      path: "/asr/transcribe",
      handler: (req) => handleTranscribe(req, transcribe),
    },
  ];
}
