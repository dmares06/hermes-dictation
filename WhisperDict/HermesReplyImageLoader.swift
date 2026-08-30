import UIKit

/// Turns the pictures in a Hermes reply into images for the bubble. Fetched
/// after the words are on screen, so a slow download never delays the answer.
enum HermesReplyImageLoader {
    private static let maxImages = 4
    private static let timeout: TimeInterval = 20

    static func load(_ references: [HermesReplyImage]) async -> [UIImage] {
        var images: [UIImage] = []
        for reference in references.prefix(maxImages) {
            if let image = await load(reference) { images.append(image) }
        }
        return images
    }

    private static func load(_ reference: HermesReplyImage) async -> UIImage? {
        switch reference {
        case .inline(let data):
            return UIImage(data: data).map(AgentAttachmentLoader.downscaled)
        case .remote(let url):
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("WhisperDict/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let image = UIImage(data: data)
                else {
                    AgentTurnLog.note("reply image unusable: \(url.host ?? "?")")
                    return nil
                }
                return AgentAttachmentLoader.downscaled(image)
            } catch {
                AgentTurnLog.note("reply image failed: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
