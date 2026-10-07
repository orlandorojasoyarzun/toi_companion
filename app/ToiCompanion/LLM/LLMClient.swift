import Foundation
import os.log

/// Streaming LLM client. Hides URLSession, the SSE parser, and the
/// TLS warm-up cadence behind a single async API.
public protocol LLMClient {
    /// Send `messages` to the model and stream the assistant's reply.
    /// `onProgress` is called with the accumulated text after every
    /// chunk; the final value is the complete reply.
    ///
    /// Cancelling the surrounding Task cancels the in-flight HTTP
    /// request and tears down the byte stream — the call throws
    /// `URLError(.cancelled)`.
    func stream(
        messages: [ChatMessage],
        model: String,
        maxTokens: Int,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

public enum LLMError: Error, CustomStringConvertible {
    case invalidResponse
    case upstream(status: Int, body: String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "invalid HTTP response"
        case .upstream(let status, let body):
            return "upstream \(status): \(body.prefix(200))"
        }
    }
}

/// OpenAI client that talks to our Cloudflare Worker (not directly to
/// OpenAI). The Worker holds the API key; we just stream through it.
///
/// TLS warm-up: every 30 minutes we HEAD the Worker URL so the next
/// real POST doesn't pay the cold-start tax (Cloudflare's edge takes
/// ~200-500ms for the first request after idle). Pattern copied from
/// HeyClicky.
public final class OpenAIClient: LLMClient {

    private let workerURL: URL
    private let secret: String
    private let session: URLSession
    private let parser = SSEParser()
    private let logger = AppLogger.make("OpenAIClient")

    public init(workerURL: URL, secret: String) {
        self.workerURL = workerURL
        self.secret = secret

        // Streaming can take ~30s on long responses. Use a generous
        // resource timeout (whole transfer) and per-request timeout
        // (between bytes). These are upper bounds, not targets — gpt-4o-mini
        // usually returns in <10s.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 5 * 60
        self.session = URLSession(configuration: config)

        startWarmupLoop()
    }

    // MARK: - Public

    public func stream(
        messages: [ChatMessage],
        model: String,
        maxTokens: Int,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {

        let request = ChatRequest(
            model: model,
            messages: messages,
            stream: true,
            maxTokens: maxTokens
        )

        var urlReq = URLRequest(url: workerURL.appendingPathComponent("chat"))
        urlReq.httpMethod = "POST"
        urlReq.setValue(secret, forHTTPHeaderField: "X-Toi-Companion-Secret")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONEncoder().encode(request)

        let (bytes, response) = try await session.bytes(for: urlReq)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // Drain the body so we can show a useful error message.
            var body = ""
            for try await byte in bytes { body.append(Character(UnicodeScalar(byte))) }
            throw LLMError.upstream(status: http.statusCode, body: body)
        }

        // `parser` may carry bytes across calls. Reset for this stream
        // so a previously-cancelled run can't leak state into this one.
        parser.reset()

        var accumulated = ""
        var streamEnded = false

        for try await byte in bytes {
            parser.ingest(Data([byte])) { payload in
                if payload == "[DONE]" {
                    streamEnded = true
                    return
                }
                // Decode the JSON chunk and append its delta. We accept
                // every decode failure silently — OpenAI has been known
                // to emit empty `choices: []` heartbeats mid-stream that
                // decode as a chunk with no delta. Those are noise, not
                // errors.
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                      let content = chunk.choices.first?.delta?.content
                else { return }
                accumulated += content
                onProgress(accumulated)
            }
        }

        // Flush any trailing bytes the server sent without a clean
        // `\n\n` terminator. Cheap insurance — costs one Data compare.
        if !streamEnded {
            parser.finish { payload in
                guard payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                      let content = chunk.choices.first?.delta?.content
                else { return }
                accumulated += content
                onProgress(accumulated)
            }
        }

        logger.info("stream finished: \(accumulated.count) chars")
        return accumulated
    }

    // MARK: - TLS warm-up

    /// Fire-and-forget task that HEADs the Worker every 30 minutes.
    /// Started once at init; lives until the process exits.
    private func startWarmupLoop() {
        Task.detached(priority: .background) { [weak self] in
            // Wait 30 minutes between warm-ups. Use `Task.sleep` so
            // cancellation propagates cleanly if the client is ever
            // deinit'd mid-loop.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard let self else { return }
                await self.warmup()
            }
        }
    }

    private func warmup() async {
        // HEAD on `/` — no auth required, exercises TLS + DNS + edge.
        let url = workerURL
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.info("TLS warm-up HEAD / -> \(status)")
        } catch {
            // Warm-up failures are not actionable for the user. Log
            // and move on — the next real POST will pay the cold-start
            // tax once and then we're back to warm.
            logger.error("TLS warm-up failed: \(error.localizedDescription)")
        }
    }
}