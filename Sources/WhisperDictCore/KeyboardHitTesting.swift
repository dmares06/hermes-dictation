import CoreGraphics

/// Which key a finger meant. A touch inside a key is that key; a touch in
/// the gap between keys is the nearest one, since a finger landing between
/// two caps still meant one of them. Anything further off than `tolerance`
/// is nothing.
public enum KeyboardHitTesting {
    public static let defaultTolerance: CGFloat = 14

    public static func key(
        at point: CGPoint,
        in frames: [KeyboardKey: CGRect],
        tolerance: CGFloat = defaultTolerance
    ) -> KeyboardKey? {
        if let hit = frames.first(where: { $0.value.contains(point) }) {
            return hit.key
        }
        var best: (key: KeyboardKey, distance: CGFloat)?
        for (key, frame) in frames {
            let distance = distance(from: point, to: frame)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (key, distance)
            }
        }
        return best?.key
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
