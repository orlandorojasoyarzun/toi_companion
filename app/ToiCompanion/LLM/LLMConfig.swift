import Foundation

/// Single-tenant configuration for the LLM proxy.
///
/// `workerBaseURL` is the public URL Cloudflare printed on deploy.
/// Public — it's not a secret, just an endpoint. The actual OpenAI key
/// never leaves the Worker.
///
/// `sharedSecret` is the 64-char hex string the user generated with
/// `openssl rand -hex 32` and set via `wrangler secret put
/// TOI_SHARED_SECRET`. It gates the proxy so a leaked URL can't be
/// abused to run up the bill. The app embeds the same value here.
///
/// Phase 5+ will move this into a settings panel + Keychain. For now
/// it's hardcoded for v1.
public enum LLMConfig {

    public static let workerBaseURL: URL = {
        guard let url = URL(string: "https://toi-companion-proxy.toi-companion.workers.dev") else {
            fatalError("LLMConfig.workerBaseURL is malformed")
        }
        return url
    }()

    /// The X-Toi-Companion-Secret header value. PASTE YOUR HEX STRING HERE.
    /// Must match `TOI_SHARED_SECRET` set on the Worker via
    /// `wrangler secret put`. Without it, every POST gets 401.
    public static let sharedSecret: String = "b317dcfd0cbb72cfa4354c0cc43fa8601401e620aa5501636e922fe32578a4f0"

    /// Default model. Mirrors `DEFAULT_MODEL` in wrangler.toml but the
    /// app sends the explicit `model` field on every request, so the
    /// Worker-side default is only a fallback.
    public static let defaultModel: String = "gpt-4o-mini"

    /// Cap output tokens per request. gpt-4o-mini supports 16k output
    /// but toi_companion lives in a sticky note — anything past ~500
    /// tokens is unreadable. Keeps cost and latency bounded.
    public static let maxOutputTokens: Int = 500
}
