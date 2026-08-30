import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Something the user picked to send along with a message: a photo Hermes can
/// look at, or a document whose text rides inside the request. Everything is
/// converted at pick time so sending is instant and failures surface while
/// the picker is still on screen.
struct AgentAttachment: Identifiable, Equatable {
    enum Payload: Equatable {
        /// Sent to the gateway as an image content part.
        case image(UIImage)
        /// Extracted text, inlined into the request under the file's name.
        case text(String)
    }

    let id = UUID()
    let name: String
    let payload: Payload

    var previewImage: UIImage? {
        if case .image(let image) = payload { return image }
        return nil
    }
}

enum AgentAttachmentError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) couldn't be read."
        case .unsupported(let name): "\(name) isn't a photo, PDF, or text file, so Hermes can't read it yet."
        case .empty(let name): "\(name) has no readable text."
        }
    }
}

enum AgentAttachmentLoader {
    /// Long edge for photos sent to the model. Bigger buys no accuracy and
    /// costs upload time on the tailnet.
    private static let maxImageDimension: CGFloat = 1568
    /// Cap for inlined document text, roughly a few thousand tokens.
    private static let maxTextCharacters = 20_000

    static func attachment(imageData data: Data, name: String) throws -> AgentAttachment {
        guard let image = UIImage(data: data) else { throw AgentAttachmentError.unreadable(name) }
        return AgentAttachment(name: name, payload: .image(downscaled(image)))
    }

    /// From the Files picker. The URL is security-scoped; access is held only
    /// long enough to copy the bytes out.
    static func attachment(fileAt url: URL) throws -> AgentAttachment {
        let name = url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw AgentAttachmentError.unreadable(name) }

        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            return try attachment(imageData: data, name: name)
        }
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(data: data) else { throw AgentAttachmentError.unreadable(name) }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AgentAttachmentError.empty(name) }
            return AgentAttachment(name: name, payload: .text(capped(text)))
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .json) == true
            || looksLikeText(data) {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AgentAttachmentError.empty(name) }
            return AgentAttachment(name: name, payload: .text(capped(text)))
        }
        throw AgentAttachmentError.unsupported(name)
    }

    /// Builds the OpenAI-style `data:` URL for an image part.
    static func imageDataURL(for image: UIImage) -> String? {
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    private static func capped(_ text: String) -> String {
        text.count <= maxTextCharacters ? text : String(text.prefix(maxTextCharacters)) + "\n[truncated]"
    }

    /// A file with no recognised extension still counts as text when its
    /// first kilobyte decodes as UTF-8 without control garbage.
    private static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(1024)
        guard let text = String(data: sample, encoding: .utf8) else { return false }
        return !text.contains { $0.asciiValue.map { $0 < 9 } ?? false }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxImageDimension, largest > 0 else { return image }
        let scale = maxImageDimension / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
