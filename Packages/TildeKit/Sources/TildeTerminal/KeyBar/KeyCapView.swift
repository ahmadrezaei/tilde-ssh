#if os(iOS)
import TildeDesign
import UIKit

/// One key of the key bar.
///
/// - Tap sends the primary action. Esc and the arrow-cluster keys send on touch-down, keys with a flick alternate
///   send on touch-up (so a flick is not preceded by a tap), and keys inside the paging area also send on touch-up so a
///   page swipe does not press anything.
/// - Flick up sends the alternate (haptic tick). Long-press on a key with an alternate shows both in a picker.
/// - Keys without an alternate auto-repeat after 400 ms at 15 Hz (modifiers, snippets and paging never repeat).
/// - Long-press on Ctrl opens the combo grid.
@MainActor
final class KeyCapView: UIView {
    static let flickDistance: CGFloat = 14
    static let longPressDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 1.0 / 15.0

    weak var bar: KeyBarView?
    private(set) var slot: KeySlot
    /// Sends the primary action on touch-down instead of touch-up.
    var sendsOnTouchDown = false
    /// Show combo grid on long-press (Ctrl).
    var opensComboGrid = false
    /// Smaller label and no alternate caption (slim strip, iPad flattened row).
    var showsAlternateCaption = true
    var labelFontSize: CGFloat = 14

    var modifierPhase: LatchPhase = .off {
        didSet { if oldValue != modifierPhase { applyState() } }
    }

    private let label = UILabel()
    private let alternateLabel = UILabel()
    private let lockGlyph = UIImageView(image: UIImage(systemName: "lock.fill"))
    private var isPressed = false { didSet { applyState() } }
    private var touchStart: CGPoint = .zero
    private var flicked = false
    private var firedOnDown = false
    private var longPressTimer: Timer?
    private var repeatTimer: Timer?
    private var didLongPress = false
    private var popover: KeyPopoverView?
    private var popoverKind: PopoverKind?

    private enum PopoverKind { case alternates, combos }
    private static let comboLetters = ["c", "d", "z", "r", "l", "a", "e", "w", "u", "k", "b"]

    init(slot: KeySlot) {
        self.slot = slot
        super.init(frame: .zero)
        layer.cornerRadius = TildeRadius.key
        layer.cornerCurve = .continuous
        layer.borderColor = KeyBarStyleKit.accent.cgColor
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        alternateLabel.textAlignment = .right
        alternateLabel.font = KeyBarStyleKit.alternateFont()
        alternateLabel.textColor = KeyBarStyleKit.text3
        lockGlyph.contentMode = .scaleAspectFit
        lockGlyph.isHidden = true
        lockGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        for subview in [label, alternateLabel, lockGlyph] {
            subview.isUserInteractionEnabled = false
            addSubview(subview)
        }
        isMultipleTouchEnabled = false
        configureAccessibility()
        reloadContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(slot: KeySlot) {
        self.slot = slot
        reloadContent()
        configureAccessibility()
    }

    private var hasAlternate: Bool { slot.alternate != nil }
    private var isModifier: Bool { slot.primary.kind == .modifier }

    private var repeats: Bool {
        guard !hasAlternate else { return false }
        switch slot.primary.kind {
        case .text, .key, .ctrl: return true
        default: return false
        }
    }

    // MARK: Layout and look

    func reloadContent() {
        label.font = KeyBarStyleKit.labelFont(size: labelFontSize)
        label.text = slot.displayLabel
        if showsAlternateCaption, let alt = slot.displayAlternateLabel {
            alternateLabel.text = alt
            alternateLabel.isHidden = false
        } else {
            alternateLabel.isHidden = true
        }
        applyState()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        alternateLabel.sizeToFit()
        let altWidth = min(alternateLabel.bounds.width, bounds.width - 4)
        alternateLabel.frame = CGRect(x: bounds.width - altWidth - 3, y: 2, width: altWidth, height: alternateLabel.bounds.height)
        lockGlyph.frame = CGRect(x: 3, y: 3, width: 9, height: 9)
    }

    private func applyState() {
        let isLocked = modifierPhase == .locked
        let isArmed = modifierPhase == .oneShot
        if isLocked {
            backgroundColor = KeyBarStyleKit.accent
            label.textColor = UIColor(TildeColor.bg)
            layer.borderWidth = 0
        } else if isArmed {
            backgroundColor = KeyBarStyleKit.accentSoft
            label.textColor = KeyBarStyleKit.accent
            layer.borderWidth = 1.5
        } else {
            backgroundColor = isPressed ? KeyBarStyleKit.keyFillPressed : KeyBarStyleKit.keyFill
            label.textColor = KeyBarStyleKit.text
            layer.borderWidth = 0
        }
        lockGlyph.isHidden = !isLocked
        lockGlyph.tintColor = UIColor(TildeColor.bg)
        if flicked, hasAlternate {
            label.alpha = 0.35
            alternateLabel.textColor = KeyBarStyleKit.accent
        } else {
            label.alpha = 1
            alternateLabel.textColor = KeyBarStyleKit.text3
        }
        if isModifier { accessibilityValue = Self.spokenState(modifierPhase) }
    }

    static func spokenState(_ phase: LatchPhase) -> String {
        switch phase {
        case .off: "off"
        case .oneShot: "one-shot"
        case .locked: "locked"
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        touchStart = touch.location(in: self)
        flicked = false
        firedOnDown = false
        didLongPress = false
        isPressed = true
        bar?.haptic(.key)
        if sendsOnTouchDown, !hasAlternate, !isModifier {
            firedOnDown = true
            fire(slot.primary)
        }
        scheduleLongPress()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        if let popover, let window = bar?.popoverWindow {
            let inWindow = convert(point, to: nil)
            let converted = self.window?.convert(inWindow, to: window) ?? inWindow
            if popover.select(atSuperviewPoint: converted) { bar?.haptic(.tick) }
            return
        }
        guard hasAlternate, !didLongPress else { return }
        let nowFlicked = (touchStart.y - point.y) >= Self.flickDistance
        if nowFlicked != flicked {
            flicked = nowFlicked
            if nowFlicked { bar?.haptic(.tick) }
            applyState()
        }
        if nowFlicked { cancelLongPress() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { finishTouch() }
        if let popover {
            switch popoverKind {
            case .alternates:
                let index = popover.selectedIndex ?? 0
                fire(index == 1 ? (slot.alternate ?? slot.primary) : slot.primary)
            case .combos:
                if let index = popover.selectedIndex { fire(.ctrl(Self.comboLetters[index])) }
            case nil:
                break
            }
            return
        }
        if didLongPress { return }   // auto-repeat already sent keys
        if flicked, let alternate = slot.alternate {
            fire(alternate)
        } else if !firedOnDown {
            fire(slot.primary)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    private func finishTouch() {
        cancelLongPress()
        repeatTimer?.invalidate()
        repeatTimer = nil
        popover?.dismiss()
        popover = nil
        popoverKind = nil
        flicked = false
        isPressed = false
    }

    private func fire(_ action: KeyAction) {
        bar?.perform(action, from: self)
    }

    // MARK: Long press: popovers and auto-repeat

    private func scheduleLongPress() {
        cancelLongPress()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressFired() }
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func longPressFired() {
        longPressTimer = nil
        guard isPressed, !flicked else { return }
        if opensComboGrid {
            didLongPress = true
            showPopover(items: Self.comboLetters.map { PopoverItem(label: "^" + $0.uppercased(), caption: nil, accessibilityLabel: "Control \($0.uppercased())") },
                        columns: 4, selection: nil, kind: .combos)
        } else if let alternate = slot.alternate {
            didLongPress = true
            showPopover(items: [
                PopoverItem(label: slot.displayLabel, caption: nil, accessibilityLabel: slot.primary.accessibilityLabel),
                PopoverItem(label: slot.displayAlternateLabel ?? alternate.defaultLabel, caption: nil, accessibilityLabel: alternate.accessibilityLabel),
            ], columns: 2, selection: 0, kind: .alternates)
        } else if repeats {
            didLongPress = true
            startRepeating()
        }
    }

    private func startRepeating() {
        fire(slot.primary)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(self?.slot.primary ?? .text("")) }
        }
    }

    private func showPopover(items: [PopoverItem], columns: Int, selection: Int?, kind: PopoverKind) {
        guard let window = bar?.popoverWindow, let ownWindow = self.window else { return }
        let view = KeyPopoverView(items: items, columns: columns, initialSelection: selection)
        let anchorInOwn = convert(bounds, to: nil)
        let anchor = ownWindow.convert(anchorInOwn, to: window)
        view.present(in: window, above: anchor)
        popover = view
        popoverKind = kind
        bar?.haptic(.tick)
    }

    // MARK: Accessibility

    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        accessibilityLabel = slot.primary.accessibilityLabel
        accessibilityHint = nil
        var actions: [UIAccessibilityCustomAction] = []
        if let alternate = slot.alternate {
            accessibilityHint = "Actions for \(alternate.accessibilityLabel)"
            actions.append(UIAccessibilityCustomAction(name: "Send \(alternate.accessibilityLabel)") { [weak self] _ in
                self?.fire(alternate)
                return true
            })
        }
        if let modifier = slot.primary.stickyModifier {
            accessibilityHint = "Arms the modifier for the next key"
            actions.append(UIAccessibilityCustomAction(name: "Lock") { [weak self] _ in
                self?.bar?.lock(modifier)
                return true
            })
        }
        if opensComboGrid {
            for letter in Self.comboLetters {
                actions.append(UIAccessibilityCustomAction(name: "Send Control \(letter.uppercased())") { [weak self] _ in
                    self?.fire(.ctrl(letter))
                    return true
                })
            }
        }
        accessibilityCustomActions = actions
    }

    override func accessibilityActivate() -> Bool {
        fire(slot.primary)
        return true
    }
}
#endif
