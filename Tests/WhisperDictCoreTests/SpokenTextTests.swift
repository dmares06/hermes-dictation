import XCTest
@testable import WhisperDictCore

final class SpokenTextImageTests: XCTestCase {
    func testPicturesAreNeverSpoken() {
        XCTAssertEqual(SpokenText.plain("Here it is. ![A russet potato](https://x.io/p.jpg)"), "Here it is.")
        XCTAssertEqual(SpokenText.plain("Done ![p](data:image/png;base64,AAAA)"), "Done")
        XCTAssertEqual(SpokenText.plain("https://v3.fal.media/files/out.jpeg"), "")
    }
}

final class SpokenSentenceSplitterTests: XCTestCase {
    func testSentencesAreReleasedAsSoonAsTheyAreComplete() {
        var splitter = SpokenSentenceSplitter()
        XCTAssertEqual(splitter.append("It is 82 degrees"), [])
        XCTAssertEqual(splitter.append(" and clear. Tomorrow "), ["It is 82 degrees and clear."])
        XCTAssertEqual(splitter.append("looks the same! Bring"), ["Tomorrow looks the same!"])
        XCTAssertEqual(splitter.flush(), "Bring")
    }

    func testDecimalsAndInitialsDoNotEndASentence() {
        var splitter = SpokenSentenceSplitter()
        XCTAssertEqual(splitter.append("Version 3.5 shipped at 4.30 p.m. today. Next"), ["Version 3.5 shipped at 4.30 p.m. today."])
        XCTAssertEqual(splitter.flush(), "Next")
    }

    func testNewlinesSeparateSentencesWithoutPunctuation() {
        var splitter = SpokenSentenceSplitter()
        XCTAssertEqual(splitter.append("First point\nSecond point\n\nThird"), ["First point", "Second point"])
        XCTAssertEqual(splitter.flush(), "Third")
    }

    func testATrailingSentenceWaitsForFlushSinceMoreMayFollow() {
        // "Done." could still be "Done.5" or "Done.js"; only the end of the
        // stream settles it, and that is what flush() is for.
        var splitter = SpokenSentenceSplitter()
        XCTAssertEqual(splitter.append("Done."), [])
        XCTAssertEqual(splitter.flush(), "Done.")
        XCTAssertNil(splitter.flush())
    }
}

final class SpokenTextTests: XCTestCase {
    func testMarkdownEmphasisAndCodeAreDropped() {
        XCTAssertEqual(SpokenText.plain("This is **very** _important_ and `code` too"), "This is very important and code too")
    }

    func testLinksReadTheirLabelAndBareURLsAreDropped() {
        XCTAssertEqual(SpokenText.plain("See [the docs](https://example.com/x) or https://example.com/y now"), "See the docs or now")
    }

    func testHeadingsAndBulletsBecomePlainLines() {
        XCTAssertEqual(SpokenText.plain("## Plan\n- first\n* second\n1. third"), "Plan\nfirst\nsecond\nthird")
    }

    func testWhitespaceIsCollapsedButLineBreaksSurvive() {
        XCTAssertEqual(SpokenText.plain("a   b \n\n\n c"), "a b\nc")
    }
}
