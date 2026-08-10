/**
 * Masks an API key for display back to the caller (the Swift Settings UI
 * included) -- once saved, only this masked form round-trips over the local
 * socket, so it must never let a real key be reconstructed.
 *
 * Rule:
 *   - length 0      -> "" (nothing to mask)
 *   - length 1..12  -> all asterisks; reveal NOTHING (short keys stay secret)
 *   - length > 12   -> a 3-char prefix + 3-char suffix, middle fully masked:
 *                      key.slice(0,3) + "*".repeat(len-6) + key.slice(-3)
 */
export function maskApiKey(apiKey: string): string {
  const len = apiKey.length;
  if (len === 0) {
    return "";
  }
  if (len <= 12) {
    return "*".repeat(len);
  }
  return `${apiKey.slice(0, 3)}${"*".repeat(len - 6)}${apiKey.slice(-3)}`;
}
