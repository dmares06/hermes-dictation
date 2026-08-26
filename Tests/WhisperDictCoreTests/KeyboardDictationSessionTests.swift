import Foundation
import Testing
@testable import WhisperDictCore

struct KeyboardDictationGateTests {
    @Test("Full access is required before anything else")
    func fullAccessRequired() {
        #expect(
            KeyboardDictationGate.blocker(
                hasFullAccess: false,
                microphoneAuthorized: true,
                speechAuthorized: true,
                recognizerAvailable: true
            ) == .needsFullAccess
        )
    }

    @Test("Denied permissions block with app guidance")
    func deniedPermissionsBlock() {
        #expect(
            KeyboardDictationGate.blocker(
                hasFullAccess: true,
                microphoneAuthorized: false,
                speechAuthorized: true,
                recognizerAvailable: true
            ) == .needsMicrophonePermission
        )
        #expect(
            KeyboardDictationGate.blocker(
                hasFullAccess: true,
                microphoneAuthorized: true,
                speechAuthorized: false,
                recognizerAvailable: true
            ) == .needsSpeechPermission
        )
    }

    @Test("Undetermined permissions are allowed through so the request can fire")
    func undeterminedPermissionsPass() {
        #expect(
            KeyboardDictationGate.blocker(
                hasFullAccess: true,
                microphoneAuthorized: nil,
                speechAuthorized: nil,
                recognizerAvailable: true
            ) == nil
        )
    }

    @Test("Unavailable recognizer blocks last")
    func recognizerUnavailableBlocks() {
        #expect(
            KeyboardDictationGate.blocker(
                hasFullAccess: true,
                microphoneAuthorized: true,
                speechAuthorized: true,
                recognizerAvailable: false
            ) == .recognizerUnavailable
        )
    }

    @Test("Every blocker has a user-facing message")
    func blockersHaveMessages() {
        let blockers: [KeyboardDictationBlocker] = [
            .needsFullAccess, .needsMicrophonePermission, .needsSpeechPermission, .recognizerUnavailable,
        ]
        for blocker in blockers {
            #expect(!blocker.message.isEmpty)
        }
    }
}

struct LiveTranscriptWriterTests {
    @Test("First partial inserts everything")
    func firstPartialInsertsEverything() {
        var writer = LiveTranscriptWriter()

        let edit = writer.edit(replacingWith: "hello")

        #expect(edit == .init(deleteCount: 0, insertText: "hello"))
        #expect(writer.insertedText == "hello")
    }

    @Test("Growing partials only append")
    func growingPartialsAppend() {
        var writer = LiveTranscriptWriter()
        _ = writer.edit(replacingWith: "hello")

        let edit = writer.edit(replacingWith: "hello world")

        #expect(edit == .init(deleteCount: 0, insertText: " world"))
    }

    @Test("Revised partials delete only the changed suffix")
    func revisedPartialsDeleteChangedSuffix() {
        var writer = LiveTranscriptWriter()
        _ = writer.edit(replacingWith: "I want to seas")

        let edit = writer.edit(replacingWith: "I want to see the ocean")

        #expect(edit.deleteCount == 2)
        #expect(edit.insertText == "e the ocean")
        #expect(writer.insertedText == "I want to see the ocean")
    }

    @Test("Identical partial is a no-op")
    func identicalPartialIsNoOp() {
        var writer = LiveTranscriptWriter()
        _ = writer.edit(replacingWith: "same text")

        let edit = writer.edit(replacingWith: "same text")

        #expect(edit.isNoOp)
    }

    @Test("Deletion counts characters, not UTF-16 units")
    func deletionCountsCharacters() {
        var writer = LiveTranscriptWriter()
        _ = writer.edit(replacingWith: "ok 👍🏽 done")

        let edit = writer.edit(replacingWith: "ok 👍🏽 finished")

        #expect(edit.deleteCount == 4)
        #expect(edit.insertText == "finished")
    }

    @Test("Finish cleans fillers and appends a trailing space")
    func finishCleansAndAppendsSpace() {
        var writer = LiveTranscriptWriter()
        _ = writer.edit(replacingWith: "um hello world")

        let edit = writer.finishEdit()

        #expect(writer.insertedText == "Hello world. ")
        #expect(edit.deleteCount == "um hello world".count)
        #expect(edit.insertText == "Hello world. ")
    }

    @Test("Finishing an empty session is a no-op")
    func finishEmptySessionIsNoOp() {
        var writer = LiveTranscriptWriter()

        let edit = writer.finishEdit()

        #expect(edit.isNoOp)
        #expect(writer.insertedText.isEmpty)
    }
}
