import UIKit

/// What the grid produces. Everything a key does that the rest of the
/// keyboard cares about; shift and 123 are handled inside the grid and
/// never cross this boundary.
protocol KeyGridViewDelegate: AnyObject {
    func keyGrid(_ grid: KeyGridView, didInsert text: String)
    func keyGridDidDelete(_ grid: KeyGridView)
    func keyGridDidRequestNextKeyboard(_ grid: KeyGridView)
    /// The click and tap a key is expected to produce, fired on touch down.
    func keyGridDidTouchKey(_ grid: KeyGridView)
}

/// The keys, in UIKit.
///
/// This was SwiftUI and it typed stiffly. Every press mutated `@State`,
/// which re-evaluated all thirty caps and recomputed the anchor
/// preferences the touch surface needed — and anchor preferences force a
/// layout pass. At the twenty-odd press and release events a second that
/// fast typing produces, the dropped frames read as dropped keystrokes.
///
/// Here a press changes one cap's background colour and nothing else: no
/// diffing, no layout, no view-graph work on the path between a finger and
/// a character. Touches are taken raw, on the way down, several at a time.
final class KeyGridView: UIView {
    weak var delegate: KeyGridViewDelegate?

    var showsNextKeyboard: Bool = true {
        didSet {
            guard showsNextKeyboard != oldValue else { return }
            caps.forEach { $0.showsNextKeyboard = showsNextKeyboard }
        }
    }

    /// Four rows of keys, and the gaps between them, at the system
    /// keyboard's proportions.
    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 7
    private static let keySpacing: CGFloat = 5
    static let preferredHeight = rowHeight * 4 + rowSpacing * 3

    private var mode: KeyboardMode = .letters
    private var isShifted = false
    private var caps: [KeyCapView] = []
    /// The touch target of each key: bigger than the cap, tiling the grid
    /// edge to edge so no touch can land in a dead gap.
    private var touchTargets: [KeyboardKey: CGRect] = [:]
    /// What each finger is holding, so a finger that slides still releases
    /// the key it actually pressed.
    private var held: [ObjectIdentifier: KeyboardKey] = [:]
    private var deleteRepeat: Timer?
    private let popup = KeyPopupView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        popup.isHidden = true
        addSubview(popup)
        rebuildCaps()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    // MARK: - Layout

    private var layout: KeyboardLayout {
        mode == .letters ? .alphabetic : .numeric
    }

    private func rebuildCaps() {
        caps.forEach { $0.removeFromSuperview() }
        caps = layout.rows.flatMap { $0 }.map { key in
            let cap = KeyCapView(key: key)
            cap.onActivate = { [weak self] in
                guard let self else { return }
                self.handle(key)
            }
            cap.shifted = isShifted
            cap.numericMode = mode == .numbers
            cap.showsNextKeyboard = showsNextKeyboard
            insertSubview(cap, belowSubview: popup)
            return cap
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        var targets: [KeyboardKey: CGRect] = [:]
        var capIndex = 0

        for (rowIndex, row) in layout.rows.enumerated() {
            let widths = keyWidths(for: row, in: bounds.width)
            let y = CGFloat(rowIndex) * (Self.rowHeight + Self.rowSpacing)
            // The outermost keys and the top and bottom rows own the margin
            // beyond them, the way the system keyboard's do: a thumb landing
            // past the last key still meant that key.
            let targetTop = rowIndex == 0 ? -Self.rowHeight : y - Self.rowSpacing / 2
            let targetBottom = rowIndex == layout.rows.count - 1
                ? bounds.height + Self.rowHeight
                : y + Self.rowHeight + Self.rowSpacing / 2
            var x: CGFloat = 0

            for (columnIndex, key) in row.enumerated() {
                let width = widths[columnIndex]
                caps[capIndex].frame = CGRect(x: x, y: y, width: width, height: Self.rowHeight)
                capIndex += 1

                let leading = columnIndex == 0 ? -bounds.width : x - Self.keySpacing / 2
                let trailing = columnIndex == row.count - 1
                    ? bounds.width * 2
                    : x + width + Self.keySpacing / 2
                targets[key] = CGRect(
                    x: leading,
                    y: targetTop,
                    width: trailing - leading,
                    height: targetBottom - targetTop
                )
                x += width + Self.keySpacing
            }
        }

        touchTargets = targets
    }

    /// Widths across one row. Everything shares the row evenly except the
    /// keys the system keyboard also makes bigger — shift, delete, return —
    /// and the space bar, which takes whatever is left. Bigger targets on
    /// the keys fingers reach for worst is most of what accuracy is.
    private func keyWidths(for row: [KeyboardKey], in width: CGFloat) -> [CGFloat] {
        let available = width - Self.keySpacing * CGFloat(row.count - 1)
        guard available > 0 else { return row.map { _ in 0 } }

        let weights = row.map { key -> CGFloat in
            switch key {
            case .shift, .delete: 1.5
            case .modeChange, .globe: 1.35
            case .returnKey: 2.0
            case .space: 0
            case .character: 1.0
            }
        }

        guard let spaceIndex = row.firstIndex(of: .space) else {
            let unit = available / weights.reduce(0, +)
            return weights.map { $0 * unit }
        }

        // The space bar is the remainder, so the bottom row always fills the
        // width exactly no matter what sits beside it.
        let unit = available / 8
        var widths = weights.map { $0 * unit }
        widths[spaceIndex] = available - widths.reduce(0, +)
        return widths
    }

    // MARK: - Touches

    // Taken raw and on the way down. A key that fires on touch-up is what
    // makes fast typing feel like it drops characters, and a gesture
    // recognizer would add its own delay before deciding.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let key = KeyboardHitTesting.nearestKey(
                at: touch.location(in: self),
                in: touchTargets
            ) else { continue }
            held[ObjectIdentifier(touch)] = key
            press(key)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func press(_ key: KeyboardKey) {
        delegate?.keyGridDidTouchKey(self)
        cap(for: key)?.isPressed = true
        if case .character = key { showPopup(for: key) }
        if key == .delete {
            startRepeatingDelete()
        } else {
            handle(key)
        }
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let key = held.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            // Another finger may still be on the same key mid-roll.
            if !held.values.contains(key) {
                cap(for: key)?.isPressed = false
                if case .character = key { hidePopup(for: key) }
            }
            if key == .delete { stopRepeatingDelete() }
        }
    }

    private func handle(_ key: KeyboardKey) {
        switch key {
        case .character:
            if let text = key.text(shifted: isShifted) {
                delegate?.keyGrid(self, didInsert: text)
            }
            if isShifted { setShifted(false) }
        case .shift:
            setShifted(!isShifted)
        case .delete:
            delegate?.keyGridDidDelete(self)
        case .modeChange:
            mode = mode == .letters ? .numbers : .letters
            isShifted = false
            rebuildCaps()
        case .globe:
            delegate?.keyGridDidRequestNextKeyboard(self)
        case .space, .returnKey:
            if let text = key.insertedText {
                delegate?.keyGrid(self, didInsert: text)
            }
        }
    }

    private func setShifted(_ shifted: Bool) {
        guard shifted != isShifted else { return }
        isShifted = shifted
        // Only the labels change, so this never re-lays out the grid.
        caps.forEach { $0.shifted = shifted }
    }

    private func cap(for key: KeyboardKey) -> KeyCapView? {
        caps.first { $0.key == key }
    }

    // MARK: - Delete repeat

    private func startRepeatingDelete() {
        stopRepeatingDelete()
        delegate?.keyGridDidDelete(self)
        // Held delete accelerates the way the system keyboard does: a pause
        // long enough to mean "I meant one character", then a steady run.
        deleteRepeat = scheduleWhileTracking(after: 0.35, repeats: false) { [weak self] in
            guard let self else { return }
            self.deleteRepeat = self.scheduleWhileTracking(after: 0.07, repeats: true) { [weak self] in
                guard let self else { return }
                self.delegate?.keyGridDidDelete(self)
            }
        }
    }

    /// A timer that keeps firing while a finger is down. The run loop is in
    /// tracking mode for the whole of a touch, and a timer scheduled the
    /// ordinary way is registered for default mode only — so held delete
    /// would sit silent until the finger lifted.
    private func scheduleWhileTracking(
        after interval: TimeInterval,
        repeats: Bool,
        _ body: @escaping () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopRepeatingDelete() {
        deleteRepeat?.invalidate()
        deleteRepeat = nil
    }

    // MARK: - Popup

    private func showPopup(for key: KeyboardKey) {
        guard let cap = cap(for: key),
              let text = key.text(shifted: isShifted),
              text.allSatisfy(\.isLetter)
        else { return }
        popup.text = text
        popup.frame = CGRect(
            x: cap.frame.midX - 27,
            y: cap.frame.minY - 56,
            width: 54,
            height: 58
        )
        popup.isHidden = false
    }

    private func hidePopup(for key: KeyboardKey) {
        // Mid-roll another finger may still be holding a letter, and its
        // popup is the one that should stay on screen.
        guard let remaining = held.values.first(where: { if case .character = $0 { true } else { false } }) else {
            popup.isHidden = true
            return
        }
        showPopup(for: remaining)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        held = [:]
        caps.forEach { $0.isPressed = false }
        popup.isHidden = true
        stopRepeatingDelete()
    }

    // MARK: - Accessibility

    override var accessibilityElements: [Any]? {
        get { caps }
        set {}
    }
}

enum KeyboardMode {
    case letters
    case numbers
}

/// One key as drawn. Pressing it changes a colour and nothing else.
private final class KeyCapView: UIView {
    let key: KeyboardKey

    var shifted = false { didSet { if shifted != oldValue { refreshContent() } } }
    var numericMode = false { didSet { if numericMode != oldValue { refreshContent() } } }
    var showsNextKeyboard = true { didSet { refreshAlpha() } }

    var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            backgroundColor = isPressed ? pressedColor : restingColor
        }
    }

    private let label = UILabel()
    private let icon = UIImageView()
    /// VoiceOver drives the key through this: the caps take no touches of
    /// their own, so without it an activated key would do nothing.
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }

    init(key: KeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        // A pre-set shadow path keeps the shadow from being recomputed on
        // every press — the reason thirty soft shadows are affordable here.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 0.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        backgroundColor = restingColor

        label.textAlignment = .center
        label.textColor = .label
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        for view in [label, icon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        refreshContent()
        refreshAlpha()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
    }

    /// A pressed cap darkens the way the system keyboard's does, so the
    /// finger gets an answer even on keys with no popup.
    private var restingColor: UIColor {
        switch key {
        case .character, .space: .systemBackground
        default: .systemGray3
        }
    }

    private var pressedColor: UIColor {
        switch key {
        case .character, .space: .systemGray4
        default: .systemBackground
        }
    }

    private func refreshAlpha() {
        alpha = key == .globe && !showsNextKeyboard ? 0.45 : 1
    }

    private func refreshContent() {
        let symbol: String?
        switch key {
        case .shift: symbol = shifted ? "shift.fill" : "shift"
        case .delete: symbol = "delete.left"
        case .globe: symbol = "globe"
        case .returnKey: symbol = "return"
        case .character, .space, .modeChange: symbol = nil
        }

        if let symbol {
            icon.image = UIImage(systemName: symbol)
            icon.isHidden = false
            label.isHidden = true
        } else {
            icon.isHidden = true
            label.isHidden = false
            switch key {
            case .modeChange:
                label.text = numericMode ? "ABC" : "123"
                label.font = .systemFont(ofSize: 15, weight: .medium)
            case .space:
                label.text = "space"
                label.font = .systemFont(ofSize: 14)
            default:
                label.text = key.text(shifted: shifted)
                label.font = .systemFont(ofSize: 22)
            }
        }
        accessibilityLabel = accessibilityName
    }

    private var accessibilityName: String {
        switch key {
        case .character: key.text(shifted: shifted) ?? "key"
        case .shift: "Shift"
        case .delete: "Delete"
        case .modeChange: numericMode ? "Letters" : "Numbers"
        case .globe: "Next keyboard"
        case .space: "Space"
        case .returnKey: "Return"
        }
    }
}

/// The magnified character shown above the finger.
private final class KeyPopupView: UIView {
    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.textAlignment = .center
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 9).cgPath
    }
}
