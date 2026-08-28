import XCTest
@testable import WhisperDictCore

final class HermesChatStreamParserTests: XCTestCase {
    private func events(_ sse: String) -> [HermesStreamEvent] {
        var parser = HermesChatStreamParser()
        var out: [HermesStreamEvent] = []
        for line in sse.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.feed(line: String(line)) { out.append(event) }
        }
        if let last = parser.finish() { out.append(last) }
        return out
    }

    private func chunk(_ delta: String, finish: String = "null", id: String = "chatcmpl-1") -> String {
        #"data: {"id": "\#(id)", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": \#(delta), "finish_reason": \#(finish)}]}"#
    }

    func testTheRoleChunkOpensTheReplyAndDeltasFollowInOrder() {
        let sse = """
        \(chunk(#"{"role": "assistant"}"#))

        \(chunk(#"{"content": "Hello, "}"#))

        \(chunk(#"{"content": "Dylan."}"#))

        """
        XCTAssertEqual(events(sse), [
            .created(responseID: "chatcmpl-1"),
            .textDelta("Hello, "),
            .textDelta("Dylan."),
        ])
    }

    func testAStopChunkCompletesWithTheWholeReply() {
        let sse = """
        \(chunk(#"{"role": "assistant"}"#))

        \(chunk(#"{"content": "It is "}"#))

        \(chunk(#"{"content": "82 degrees."}"#))

        \(chunk("{}", finish: #""stop""#))

        data: [DONE]

        """
        XCTAssertEqual(events(sse).last, .completed(responseID: "chatcmpl-1", text: "It is 82 degrees."))
        XCTAssertEqual(events(sse).count, 4)
    }

    func testToolProgressEventsBecomeToolStartedAndFinished() {
        let sse = """
        event: hermes.tool.progress
        data: {"tool": "web_search", "emoji": "🔍", "label": "web_search(flights)", "toolCallId": "call_1", "status": "running"}

        event: hermes.tool.progress
        data: {"tool": "web_search", "toolCallId": "call_1", "status": "completed"}

        """
        XCTAssertEqual(events(sse), [
            .toolStarted(name: "web_search", callID: "call_1"),
            .toolFinished(callID: "call_1"),
        ])
    }

    func testAnErrorFinishCarriesTheGatewaysMessage() {
        let sse = """
        \(chunk(#"{"role": "assistant"}"#))

        data: {"id": "chatcmpl-1", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": "error"}], "error": {"message": "upstream 502", "type": "agent_error"}}

        """
        XCTAssertEqual(events(sse).last, .failed(message: "upstream 502"))
    }

    func testATopLevelErrorObjectFails() {
        let sse = """
        data: {"error": {"message": "Session continuation requires API key authentication."}}

        """
        XCTAssertEqual(events(sse), [.failed(message: "Session continuation requires API key authentication.")])
    }

    func testKeepalivesAndUnknownFramesAreIgnored() {
        let sse = """
        : keepalive

        data: {"object": "something.else"}

        \(chunk(#"{"content": "hi"}"#))
        """
        XCTAssertEqual(events(sse), [.textDelta("hi")])
    }

    func testMultiLineDataFramesAreJoined() {
        let sse = """
        data: {"id": "chatcmpl-9", "object": "chat.completion.chunk",
        data:  "choices": [{"index": 0, "delta": {"content": "two lines"}, "finish_reason": null}]}

        """
        XCTAssertEqual(events(sse), [.textDelta("two lines")])
    }
}
