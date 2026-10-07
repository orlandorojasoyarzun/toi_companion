import XCTest
@testable import ToiCompanion

/// Tests for the byte-incremental SSE parser. We feed arbitrary
/// chunks of bytes (some split mid-event, some carrying multiple
/// events, some missing the final `\n\n`) and verify the yielded
/// payloads match what OpenAI would actually send.
final class SSEParserTests: XCTestCase {

    private func parse(_ feeds: [Data]) -> [String] {
        let parser = SSEParser()
        var payloads: [String] = []
        for chunk in feeds {
            parser.ingest(chunk) { payloads.append($0) }
        }
        parser.finish { payloads.append($0) }
        return payloads
    }

    /// Single complete event in one feed. Trivial happy path.
    func testSingleCompleteEvent() {
        let feed = Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n".utf8)
        XCTAssertEqual(parse([feed]), ["{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"])
    }

    /// Event split across two feeds. The carry buffer must hold the
    /// half event across `ingest` calls without dropping it.
    func testEventSplitAcrossFeeds() {
        let part1 = Data("data: {\"choices\":[{\"delta\":{\"cont".utf8)
        let part2 = Data("ent\":\"hi\"}}]}\n\n".utf8)
        XCTAssertEqual(parse([part1, part2]), ["{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}"])
    }

    /// Two complete events in one feed.
    func testTwoEventsInOneFeed() {
        let feed = Data("data: first\n\ndata: second\n\n".utf8)
        XCTAssertEqual(parse([feed]), ["first", "second"])
    }

    /// Feed ends with a half event and no trailing `\n\n`. `finish`
    /// must flush it.
    func testFinishFlushesTrailingEvent() {
        let feed = Data("data: dangling".utf8)
        XCTAssertEqual(parse([feed]), ["dangling"])
    }

    /// CRLF line endings (some servers / proxies use them).
    func testCRLFLineEndings() {
        let feed = Data("data: crlf\r\n\r\n".utf8)
        XCTAssertEqual(parse([feed]), ["crlf"])
    }

    /// Lines that aren't `data: ` are silently ignored (SSE spec also
        /// defines `event:`, `id:`, `retry:` — OpenAI emits none of
        /// those, but the parser shouldn't choke if it sees them).
    func testIgnoresNonDataLines() {
        let feed = Data("event: message\nid: 42\nretry: 1000\ndata: payload\n\n".utf8)
        XCTAssertEqual(parse([feed]), ["payload"])
    }

    /// `[DONE]` sentinel is yielded as a payload — the caller decides
        /// what to do with it.
    func testDoneSentinelIsYielded() {
        let feed = Data("data: [DONE]\n\n".utf8)
        XCTAssertEqual(parse([feed]), ["[DONE]"])
    }

    /// Empty data lines (a blank `data:`) yield an empty payload.
    func testEmptyDataLineYieldsEmptyPayload() {
        let feed = Data("data:\n\n".utf8)
        XCTAssertEqual(parse([feed]), [""])
    }

    /// Stress: 1000 small events across 100 feeds. Catches O(n²)
    /// regressions in the carry buffer or split.
    func testManySmallEventsAcrossManyFeeds() {
        let parser = SSEParser()
        var payloads: [String] = []
        for i in 0..<1000 {
            let bytes = Data("data: \(i)\n\n".utf8)
            // Feed in arbitrary chunks to exercise the carry path.
            let mid = bytes.count / 2
            parser.ingest(bytes.prefix(mid)) { payloads.append($0) }
            parser.ingest(bytes.suffix(from: mid)) { payloads.append($0) }
        }
        XCTAssertEqual(payloads.count, 1000)
        XCTAssertEqual(payloads.first, "0")
        XCTAssertEqual(payloads.last, "999")
    }
}