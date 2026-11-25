#if os(iOS)
import TildeDesign
import UIKit

/// The arrow joystick (docs/DESIGN.md section 5.3).
///
/// Drag from the key in any direction: after 8 pt it sends that arrow and holding repeats it. The repeat rate grows
/// with distance (8-28 pt: 8 Hz, 28-60 pt: 20 Hz, beyond: 40 Hz). Diagonals snap to the dominant axis. A tap toggles
/// the arrow page. Arrows go through the delegate as `.key` actions, so DECCKM and sticky modifiers apply.
@MainActor
final class JoystickView: UIView {
    static let activationDistance: CGFloat = 8

    weak var bar: KeyBarView?
    private let glyph = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
    private var start: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var direction: NamedKey?
    private var rate: Double = 0
    private var timer: Timer?
    private var bubble: KeyPopoverView?
    private var didDrag = false
    var isArrowPageActive = false { didSet { applyState() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = TildeRadius.key
        layer.cornerCurve = .continuous
        glyph.contentMode = .scaleAspectFit
        glyph.isUserInteractionEnabled = false
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        addSubview(glyph)
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityTraits = [.button, .keyboardKey]
        accessibilityLabel = "Arrow keys"
        accessibilityHint = "Double tap to switch the key page to arrows. Use the actions rotor to send a single arrow."
        accessibilityCustomActions = [
            ("Up arrow", NamedKey.up), ("Down arrow", .down), ("Left arrow", .left), ("Right arrow", .right),
        ].map { name, key in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.send(key)
                return true
            }
        }
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
    }

    private func applyState() {
        backgroundColor = isArrowPageActive ? KeyBarStyleKit.accentSoft : KeyBarStyleKit.keyFill
        glyph.tintColor = isArrowPageActive ? KeyBarStyleKit.accent : KeyBarStyleKit.text
        layer.borderColor = KeyBarStyleKit.accent.cgColor
        layer.borderWidth = isArrowPageActive ? 1.5 : 0
        accessibilityValue = isArrowPageActive ? "arrow page showing" : nil
    }

    override func accessibilityActivate() -> Bool {
        bar?.toggleArrowPage()
        return true
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        start = touch.location(in: self)
        startTime = touch.timestamp
        didDrag = false
        direction = nil
        backgroundColor = KeyBarStyleKit.keyFillPressed
        bar?.haptic(.key)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let dx = point.x - start.x, dy = point.y - start.y
        let distance = hypot(dx, dy)
        guard distance >= Self.activationDistance else {
            if direction != nil { stopRepeating() }
            return
        }
        didDrag = true
        let new: NamedKey = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        let newRate = Self.rate(forDistance: distance)
        if new != direction {
            direction = new
            rate = newRate
            send(new)
            showBubble(for: new)
            restartTimer()
        } else if newRate != rate {
            rate = newRate
            restartTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let duration = (touches.first?.timestamp ?? startTime) - startTime
        let wasTap = !didDrag && duration < 0.5
        finish()
        if wasTap { bar?.toggleArrowPage() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }

    private func finish() {
        stopRepeating()
        bubble?.dismiss()
        bubble = nil
        applyState()
    }

    /// Repeat rate in Hz for a drag distance in points.
    static func rate(forDistance distance: CGFloat) -> Double {
        switch distance {
        case ..<28: 8
        case ..<60: 20
        default: 40
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let direction = self.direction else { return }
                self.send(direction)
            }
        }
    }

    private func stopRepeating() {
        timer?.invalidate()
        timer = nil
        direction = nil
    }

    private func send(_ key: NamedKey) {
        bar?.haptic(.tick)
        bar?.perform(.key(key), from: self)
    }

    private func showBubble(for key: NamedKey) {
        bubble?.dismiss()
        guard let window = bar?.popoverWindow, let ownWindow = self.window else { return }
        let view = KeyPopoverView(items: [PopoverItem(label: key.shortLabel, caption: nil, accessibilityLabel: "")], columns: 1, initialSelection: 0)
        view.present(in: window, above: ownWindow.convert(convert(bounds, to: nil), to: window))
        bubble = view
    }
}
#endif
