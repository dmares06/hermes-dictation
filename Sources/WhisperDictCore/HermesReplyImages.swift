import Foundation

/// A picture Hermes put in a reply: somewhere on the web, or inlined by the
/// gateway as a data URL when the image was generated on the Mac.
public enum HermesReplyImage: Equatable, Sendable {
    case remote(URL)
    case inline(Data)
}

/// Pulls the pictures out of a reply so the phone can show them and the
/// voice can skip them. Markdown images, bare data URLs and bare links to
/// image files all count; what remains is the reply without them.
public enum HermesReplyImages {
    public struct Extracted: Equatable, Sendable {
        public let text: String
        public let images: [HermesReplyImage]
    }

    private static let markdownImage = #"!\[[^\]]*\]\(\s*<?([^)\s]+)>?\s*\)"#
    private static let dataURL = #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#
    private static let imageLink = #"(?i)https?://[^\s<>()\[\]]+?\.(?:png|jpe?g|gif|webp|avif)(?:\?[^\s<>()\[\]]*)?"#

    public static func extract(from reply: String) -> Extracted {
        var text = reply
        var found: [HermesReplyImage] = []

        for match in matches(of: markdownImage, in: text, group: 1) {
            if let image = image(from: match) { found.append(image) }
        }
        text = text.replacingOccurrences(of: markdownImage, with: "", options: .regularExpression)

        for match in matches(of: dataURL, in: text, group: 0) {
            if let image = image(from: match) { found.append(image) }
        }
        text = text.replacingOccurrences(of: dataURL, with: "", options: .regularExpression)

        for match in matches(of: imageLink, in: text, group: 0) {
            if let image = image(from: match) { found.append(image) }
        }
        text = text.replacingOccurrences(of: imageLink, with: "", options: .regularExpression)

        var unique: [HermesReplyImage] = []
        for image in found where !unique.contains(image) { unique.append(image) }
        return Extracted(text: text, images: unique)
    }

    private static func image(from reference: String) -> HermesReplyImage? {
        if reference.hasPrefix("data:image/") {
            guard let comma = reference.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(reference[reference.index(after: comma)...])),
                  !data.isEmpty
            else { return nil }
            return .inline(data)
        }
        guard let url = URL(string: reference), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return .remote(url)
    }

    private static func matches(of pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
