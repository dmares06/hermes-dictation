import XCTest
@testable import WhisperDictCore

final class HermesReplyImagesTests: XCTestCase {
    func testMarkdownImageBecomesARemotePictureAndLeavesTheSentence() {
        let reply = "Here is a russet potato.\n![A russet potato](https://upload.wikimedia.org/potato.jpg)"
        let extracted = HermesReplyImages.extract(from: reply)
        XCTAssertEqual(extracted.images, [.remote(URL(string: "https://upload.wikimedia.org/potato.jpg")!)])
        XCTAssertEqual(extracted.text.trimmingCharacters(in: .whitespacesAndNewlines), "Here is a russet potato.")
    }

    func testGeneratedImagesArriveAsDataURLs() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="
        let reply = "Done. ![potato](data:image/png;base64,\(png))"
        let extracted = HermesReplyImages.extract(from: reply)
        XCTAssertEqual(extracted.images, [.inline(Data(base64Encoded: png)!)])
        XCTAssertEqual(extracted.text.trimmingCharacters(in: .whitespacesAndNewlines), "Done.")
    }

    func testBareLinksToImageFilesCountAndLinksToPagesDoNot() {
        let reply = "See https://v3.fal.media/files/x/out.jpeg?token=1 and https://en.wikipedia.org/wiki/Potato"
        let extracted = HermesReplyImages.extract(from: reply)
        XCTAssertEqual(extracted.images, [.remote(URL(string: "https://v3.fal.media/files/x/out.jpeg?token=1")!)])
        XCTAssertTrue(extracted.text.contains("https://en.wikipedia.org/wiki/Potato"))
    }

    func testTheSamePictureIsListedOnce() {
        let reply = "![a](https://x.io/a.png) again https://x.io/a.png"
        XCTAssertEqual(HermesReplyImages.extract(from: reply).images.count, 1)
    }

    func testUnsafeSchemesAreIgnored() {
        let extracted = HermesReplyImages.extract(from: "![x](file:///etc/passwd) ![y](javascript:alert(1))")
        XCTAssertEqual(extracted.images, [])
    }
}
