import SwiftUI
import UIKit

/// The one thing SwiftUI cannot do for a keyboard: track several fingers at
/// once. Fast typing rolls from one key to the next with the first finger
/// still down, and a single-touch gesture drops the second key every time.
/// This sits over the key grid, takes every touch on the way down, and maps
/// each one to the key under (or nearest) it — touch down types, touch up
/// only releases, exactly like the caps it covers.
struct KeyTouchSurface: UIViewRepresentable {
    let frames: [KeyboardKey: CGRect]
    let onPress: (KeyboardKey) -> Void
    let onRelease: (KeyboardKey) -> Void

    func makeUIView(context: Context) -> KeyTouchView {
        let view = KeyTouchView()
        view.frames = frames
        view.onPress = onPress
        view.onRelease = onRelease
        return view
    }

    func updateUIView(_ view: KeyTouchView, context: Context) {
        view.frames = frames
        view.onPress = onPress
        view.onRelease = onRelease
    }
}

final class KeyTouchView: UIView {
    var frames: [KeyboardKey: CGRect] = [:]
    var onPress: (KeyboardKey) -> Void = { _ in }
    var onRelease: (KeyboardKey) -> Void = { _ in }
    /// The key each finger is holding, so a finger that slides still
    /// releases the key it pressed.
    private var held: [ObjectIdentifier: KeyboardKey] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        // VoiceOver reaches the caps underneath, which carry the labels.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let key = KeyboardHitTesting.key(at: touch.location(in: self), in: frames) else { continue }
            held[ObjectIdentifier(touch)] = key
            onPress(key)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            if let key = held.removeValue(forKey: ObjectIdentifier(touch)) { onRelease(key) }
        }
    }
}
