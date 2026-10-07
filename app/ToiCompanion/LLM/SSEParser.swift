import Foundation

/// Incremental parser for Server-Sent Events in OpenAI's chat stream
/// format. Splits bytes on `\n\n` event boundaries and yields each
/// `data: ` line as a payload string.
///
/// The parser is byte-agnostic — it knows nothing about ChatChunk,
/// deltas, or the OpenAI schema. The caller decides what each payload
/// means and accumulates state. This keeps the parser testable in
/// isolation with arbitrary chunked bytes (see SSEParserTests).
///
/// Why not just `String(data:)` and `String.split`? Because we get
/// bytes incrementally over a streaming HTTP response. The final
/// chunk may arrive with a half-formed event at the tail — we have
/// to hold onto it and wait for the rest. Doing that with `Data`
/// buffers (not `String`) avoids transcoding incomplete UTF-8.
public final class SSEParser {

    /// Bytes from the previous `ingest` that didn't end on an event
    /// boundary. Carried across calls until we see `\n\n`.
    private var carry = Data()

    /// SSE event separator: a blank line. Two line feeds in a row.
    private static let eventSeparator = Data("\n\n".utf8)

    /// Public for tests; in production the parser is stateless to
    /// callers — they just feed bytes.
    public init() {}

    /// Feed bytes from the streaming response. Calls `onPayload` once
    /// per `data: ` line found inside a complete SSE event. The
    /// "[DONE]" sentinel (OpenAI's end-of-stream marker) is yielded
    /// as a payload too — callers should treat it as "no more data"
    /// rather than a JSON message.
    ///
    /// Lines that aren't `data: ` are ignored (SSE spec also defines
    /// `event:`, `id:`, `retry:` — none of which OpenAI emits).
    public func ingest(_ bytes: Data, onPayload: (String) -> Void) {
        carry.append(bytes)

        // Pull complete events off the front of the buffer, leaving
        // the trailing partial event in `carry` for the next call.
        while let separatorRange = carry.range(of: Self.eventSeparator) {
            let eventData = carry.subdata(in: 0..<separatorRange.lowerBound)
            carry.removeSubrange(0..<separatorRange.upperBound)
            emitPayloads(from: eventData, onPayload: onPayload)
        }
    }

    /// Force any bytes still in `carry` to be flushed as a final event.
    /// Call this when the upstream closes the stream without a clean
    /// `\n\n` terminator. Some servers (and curl with `-N`) close mid-
    /// event; we don't want to lose the last message.
    public func finish(onPayload: (String) -> Void) {
        if !carry.isEmpty {
            emitPayloads(from: carry, onPayload: onPayload)
            carry.removeAll()
        }
    }

    /// Discard any partial event in `carry`. Used between independent
    /// streams (e.g. a cancelled stream followed by a fresh one on the
    /// same parser instance) so leftover bytes from the dead run can't
    /// leak into the new one.
    public func reset() {
        carry.removeAll()
    }

    // MARK: - Private

    private func emitPayloads(from eventData: Data, onPayload: (String) -> Void) {
        // UTF-8 decode the whole event. If it fails (e.g. line feeds
        // split a multi-byte char) we just skip — OpenAI always sends
        // ASCII control chars + JSON, so this is degenerate but safe.
        guard let text = String(data: eventData, encoding: .utf8) else { return }

        // Normalise line endings. Two notes:
        //  1. CRLF (`\r\n`) is a single Character in Swift (extended
        //     grapheme cluster), so `split(separator: "\n")` would
        //     NOT cut on CRLF line endings — it would treat the whole
        //     feed as one line. Replace CRLF with LF first.
        //  2. A lone `\r` (old-Mac line endings) is normalised to LF
        //     too. Not a concern with OpenAI, but defensive and free.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // SSE spec: a "data" field with no value (or just a colon,
            // or just a colon and one space) represents an empty payload.
            // OpenAI never sends these, but a permissive parser is
            // friendlier than a strict one.
            if line == "data" || line == "data:" || line == "data: " {
                onPayload("")
                continue
            }

            guard line.hasPrefix("data: ") else { continue }
            onPayload(String(line.dropFirst("data: ".count)))
        }
    }
}