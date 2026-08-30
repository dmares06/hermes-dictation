import Foundation

/// A Hermes reply as it streams in, deciding what can be said right away and
/// what has to wait.
///
/// Two things must not be spoken early: anything after a `<`, because it may
/// be the start of an action block, and the trailing sentence, because the
/// stream alone cannot tell "Done." from "Done.js". Both come out of
/// `finish`, along with the action the block asked for.
public struct HermesStreamedSpeech: Sendable {
    public struct Finished: Equatable, Sendable {
        /// What goes in the transcript: the reply minus any action block.
        public let spoken: String
        public let action: VoiceAgentAction?
        /// What is still to be said aloud after the streamed sentences.
        public let remainingSpeech: String?
        /// Pictures the reply carried, for the bubble; none are spoken.
        public var images: [HermesReplyImage] = []
    }

    private var raw = ""
    /// How many characters of `raw` the sentence splitter has been given.
    private var fedCount = 0
    private var splitter = SpokenSentenceSplitter()

    public init() {}

    /// The reply so far, as the transcript should show it while it is still
    /// arriving. A half-received action block is cut off rather than shown.
    public var displayText: String {
        var shown = raw
        if let open = shown.range(of: HermesActionBlock.openTag),
           shown.range(of: HermesActionBlock.closeTag) == nil {
            shown = String(shown[..<open.lowerBound])
        }
        // Plain for the bubble as well as the voice: the transcript renders
        // text, not markdown.
        return SpokenText.plain(HermesActionBlock.extract(from: shown).spoken)
    }

    /// Takes one delta and returns the sentences that are now safe to speak,
    /// already stripped of markdown.
    public mutating func append(_ delta: String) -> [String] {
        raw += delta
        let safeEnd = raw.firstIndex(of: "<").map { raw.distance(from: raw.startIndex, to: $0) } ?? raw.count
        guard safeEnd > fedCount else { return [] }
        let start = raw.index(raw.startIndex, offsetBy: fedCount)
        let end = raw.index(raw.startIndex, offsetBy: safeEnd)
        fedCount = safeEnd
        return splitter.append(String(raw[start..<end]))
            .map(SpokenText.plain)
            .filter { !$0.isEmpty }
    }

    /// Settles the reply once the stream has ended. `completedText` is the
    /// server's copy of the whole reply, used only if no deltas arrived.
    public mutating func finish(completedText: String?) -> Finished {
        if raw.isEmpty, let completedText { raw = completedText }
        let parsed = HermesActionBlock.extract(from: raw)
        let unfed = String(raw.dropFirst(fedCount))
        let unspoken = [splitter.flush(), HermesActionBlock.extract(from: unfed).spoken]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let remainder = SpokenText.plain(unspoken)
        return Finished(
            spoken: SpokenText.plain(parsed.spoken),
            action: parsed.action,
            remainingSpeech: remainder.isEmpty ? nil : remainder,
            images: HermesReplyImages.extract(from: parsed.spoken).images
        )
    }
}
