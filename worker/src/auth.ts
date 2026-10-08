/**
 * Constant-time shared-secret check.
 *
 * Why not `===`? A naive string compare short-circuits on the first
 * mismatched character, leaking how many leading bytes matched via
 * timing. The XOR-then-OR trick runs the same number of ops no matter
 * where the first mismatch is, so an attacker can't time-probe the
 * secret. This is the same approach the Cloudflare Workers docs use
 * for API token validation.
 *
 * Length check is done up front because otherwise a zero-length
 * provided secret would trivially pass the loop (every XOR is 0).
 */
export function authorise(req: Request, secret: string): boolean {
  const provided = req.headers.get("X-Toi-Companion-Secret") ?? "";
  if (provided.length !== secret.length) return false;
  let mismatch = 0;
  for (let i = 0; i < secret.length; i++) {
    mismatch |= provided.charCodeAt(i) ^ secret.charCodeAt(i);
  }
  return mismatch === 0;
}
