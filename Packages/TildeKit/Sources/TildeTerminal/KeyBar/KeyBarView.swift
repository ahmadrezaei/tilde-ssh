#if os(iOS)
import TildeDesign
import UIKit

/// What the key bar asks of the terminal it belongs to.
@MainActor
protocol KeyBarViewDelegate: AnyObject {
    func keyBar(_ bar: KeyBarView, perform action: KeyAction)
    func keyBarRequestsSnippets(_ bar: KeyBarView, from source: UIView)
    func keyBarHapticsEnabled(_ bar: KeyBarView) -> Bool
    /// The app window, for popovers that extend above the keyboard.
    func keyBarPopoverWindow(_ bar: KeyBarView) -> UIWindow?
}

enum KeyBarHaptic { case key, tick, lock }

/// The SSH key bar: the terminal's `inputAccessoryView` (docs/DESIGN.md section 5).
///
/// - iPhone: Esc, Ctrl and Alt pinned left, the arrow joystick pinned right, and a paging area of 6 keys per page.
///   With an accessibility text size the bar becomes two rows instead of shrinking labels.
/// - iPad: one wide row with every page flattened (alternates become keys) and an inline arrow cluster.
/// - Hardware keyboard: a slim strip with Esc, F1-F12, snippets, Ctrl and a hide button.
@MainActor
final class KeyBarView: UIView, UIScrollViewDelegate {
    weak var delegate: KeyBarViewDelegate?

    var configuration: KeyBarConfiguration {
        didSet { if oldValue.layout != configuration.layout { rebuild() } }
    }
    var style: KeyBarStyle = .full {
        didSet { if oldValue != style { rebuild() } }
    }
    var inputState: TerminalInputState? {
        didSet { refreshModifiers() }
    }

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let lockImpact = UIImpactFeedbackGenerator(style: .medium)

    // Built content
    private var pinned: [KeyCapView] = []
    private var trailingPinned: [KeyCapView] = []
    private var pagerCaps: [[KeyCapView]] = []
    private let pager = UIScrollView()
    private var dots: [UIView] = []
    private var joystick: JoystickView?
    private var arrowCluster: [KeyCapView] = []
    private var arrowPage: UIView?
    private var arrowPageCaps: [KeyCapView] = []
    private var builtKey = ""
    private var lastPhases: [KeyModifiers.RawValue: LatchPhase] = [:]
    private var currentPage = 0

    init(configuration: KeyBarConfiguration) {
        self.configuration = configuration
        // A plain UIView, not UIInputView(.keyboard): the latter did not deliver touches to the keys on iOS 27.
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46))
        autoresizingMask = .flexibleHeight
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.isDirectionalLockEnabled = true
        pager.alwaysBounceVertical = false
        pager.delaysContentTouches = false
        pager.canCancelContentTouches = true
        pager.delegate = self
        pager.clipsToBounds = true
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Terminal key bar"
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceIdiom.self]) { (self: KeyBarView, _) in
            self.rebuildIfNeeded()
        }
        impact.prepare()
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Services for key caps

    var popoverWindow: UIWindow? { delegate?.keyBarPopoverWindow(self) }

    func haptic(_ kind: KeyBarHaptic) {
        guard delegate?.keyBarHapticsEnabled(self) ?? true else { return }
        switch kind {
        case .key: impact.impactOccurred(intensity: 0.7)
        case .tick: selection.selectionChanged()
        case .lock: lockImpact.impactOccurred()
        }
    }

    func perform(_ action: KeyAction, from source: UIView) {
        switch action.kind {
        case .snippets:
            delegate?.keyBarRequestsSnippets(self, from: source)
        case .modifier:
            if let modifier = action.stickyModifier, inputState?.latch.phase(of: modifier) == .oneShot { haptic(.lock) }
            delegate?.keyBar(self, perform: action)
        default:
            delegate?.keyBar(self, perform: action)
        }
    }

    func lock(_ modifier: KeyModifiers) {
        inputState?.lock(modifier)
    }

    // MARK: Modifier state

    func refreshModifiers() {
        guard let inputState else { return }
        let all = pinned + trailingPinned + pagerCaps.flatMap { $0 } + arrowCluster
        for cap in all {
            guard let modifier = cap.slot.primary.stickyModifier else { continue }
            let phase = inputState.latch.phase(of: modifier)
            cap.modifierPhase = phase
            if lastPhases[modifier.rawValue] != phase {
                lastPhases[modifier.rawValue] = phase
                let name = cap.slot.primary.accessibilityLabel
                UIAccessibility.post(notification: .announcement, argument: "\(name), \(KeyCapView.spokenState(phase))")
            }
        }
    }

    // MARK: Building

    private var isPad: Bool { traitCollection.userInterfaceIdiom == .pad }
    private var isLargeText: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    private var buildSignature: String {
        "\(style)-\(isPad)-\(isLargeText)-\(configuration.layout.pages.count)"
    }

    private func rebuildIfNeeded() {
        if builtKey != buildSignature { rebuild() }
    }

    private var rowCount: Int { style == .full && !isPad && isLargeText ? 2 : 1 }

    private var barHeight: CGFloat {
        switch style {
        case .slim, .hidden: TildeSpacing.keyBarSlim
        case .full: isPad ? TildeSpacing.keyBarPad : TildeSpacing.keyBarPhone * CGFloat(rowCount)
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: barHeight) }

    private func cap(_ action: KeyAction, alternate: KeyAction? = nil, label: String? = nil, onDown: Bool = false) -> KeyCapView {
        let cap = KeyCapView(slot: KeySlot(action, alternate: alternate, label: label))
        cap.bar = self
        cap.sendsOnTouchDown = onDown
        return cap
    }

    private func slotCap(_ slot: KeySlot) -> KeyCapView {
        let cap = KeyCapView(slot: slot)
        cap.bar = self
        return cap
    }

    private func rebuild() {
        builtKey = buildSignature
        subviews.forEach { $0.removeFromSuperview() }
        pinned = []; trailingPinned = []; pagerCaps = []; dots = []; arrowCluster = []
        joystick = nil; arrowPage = nil; arrowPageCaps = []
        pager.subviews.forEach { $0.removeFromSuperview() }
        currentPage = 0
        pager.contentOffset = .zero

        let esc = cap(.key(.escape), onDown: true)
        let ctrl = cap(.modifier(.ctrl))
        ctrl.opensComboGrid = true
        let alt = cap(.modifier(.alt))

        switch style {
        case .hidden:
            break
        case .slim:
            buildSlim(esc: esc, ctrl: ctrl)
        case .full:
            pinned = configuration.layout.showsAlt ? [esc, ctrl, alt] : [esc, ctrl]
            pinned.forEach(addSubview)
            if isPad { buildPadRow() } else { buildPhonePager() }
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        refreshModifiers()
    }

    private func buildPhonePager() {
        addSubview(pager)
        for page in configuration.layout.pages {
            var caps: [KeyCapView] = []
            for slot in page.slots {
                let cap = slotCap(slot)
                pager.addSubview(cap)
                caps.append(cap)
            }
            pagerCaps.append(caps)
        }
        if configuration.layout.pages.count > 1 {
            for _ in configuration.layout.pages {
                let dot = UIView()
                dot.layer.cornerRadius = 2
                dot.isUserInteractionEnabled = false
                addSubview(dot)
                dots.append(dot)
            }
        }
        let stick = JoystickView()
        stick.bar = self
        addSubview(stick)
        joystick = stick
        updateDots()
    }

    /// iPad: every page flattened; flick alternates become keys of their own.
    private func buildPadRow() {
        addSubview(pager)
        var caps: [KeyCapView] = []
        for page in configuration.layout.pages {
            for slot in page.slots {
                var primary = slot
                primary.alternate = nil
                primary.alternateLabel = nil
                caps.append(slotCap(primary))
                if let alternate = slot.alternate {
                    caps.append(slotCap(KeySlot(alternate, label: slot.displayAlternateLabel)))
                }
            }
        }
        for cap in caps {
            cap.showsAlternateCaption = false
            cap.labelFontSize = 16
            cap.reloadContent()
            pager.addSubview(cap)
        }
        pagerCaps = [caps]
        pager.isPagingEnabled = false
        let up = cap(.key(.up), label: "↑", onDown: true)
        let down = cap(.key(.down), label: "↓", onDown: true)
        let left = cap(.key(.left), label: "←", onDown: true)
        let right = cap(.key(.right), label: "→", onDown: true)
        arrowCluster = [left, down, up, right]
        arrowCluster.forEach(addSubview)
    }

    private func buildSlim(esc: KeyCapView, ctrl: KeyCapView) {
        pinned = [esc]
        trailingPinned = [ctrl, cap(.snippets), cap(.hideKeyboard)]
        (pinned + trailingPinned).forEach { $0.labelFontSize = 13; $0.showsAlternateCaption = false; $0.reloadContent(); addSubview($0) }
        addSubview(pager)
        pager.isPagingEnabled = false
        var caps: [KeyCapView] = []
        for n in 1...12 {
            let key = cap(.key(NamedKey.function(n)!), onDown: false)
            key.labelFontSize = 13
            key.reloadContent()
            pager.addSubview(key)
            caps.append(key)
        }
        pagerCaps = [caps]
    }

    // MARK: Arrow page (joystick tap)

    func toggleArrowPage() {
        guard style == .full, !isPad else { return }
        if arrowPage != nil { hideArrowPage() } else { showArrowPage() }
    }

    private func showArrowPage() {
        let page = UIView()
        page.backgroundColor = .clear
        let keys: [(KeyAction, String)] = [
            (.key(.left), "←"), (.key(.down), "↓"), (.key(.up), "↑"), (.key(.right), "→"), (.key(.home), "home"), (.key(.end), "end"),
        ]
        for (action, label) in keys {
            let key = cap(action, label: label, onDown: true)
            page.addSubview(key)
            arrowPageCaps.append(key)
        }
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(arrowPageSwiped))
            swipe.direction = direction
            page.addGestureRecognizer(swipe)
        }
        addSubview(page)
        arrowPage = page
        joystick?.isArrowPageActive = true
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func hideArrowPage() {
        arrowPage?.removeFromSuperview()
        arrowPage = nil
        arrowPageCaps = []
        joystick?.isArrowPageActive = false
    }

    @objc private func arrowPageSwiped() { hideArrowPage() }

    // MARK: Layout

    private let inset: CGFloat = 4, gap: CGFloat = 3, gutter: CGFloat = 6

    override func layoutSubviews() {
        super.layoutSubviews()
        switch style {
        case .hidden: break
        case .slim: layoutSlim()
        case .full: isPad ? layoutPad() : layoutPhone()
        }
    }

    private func layoutPhone() {
        let w = bounds.width
        let rows = rowCount
        let rowHeight = TildeSpacing.keyBarPhone
        let keyHeight: CGFloat = 38
        let pages = max(1, configuration.layout.pages.count)
        let dotsHeight: CGFloat = dots.isEmpty ? 0 : 7
        if rows == 1 {
            let pinnedCount = CGFloat(pinned.count)
            let slots = pinnedCount + 6 + 1
            let usable = w - inset * 2 - gap * (pinnedCount - 1) - gap * 5 - gutter * 2
            let keyWidth = max(26, usable / slots)
            var x = inset
            let y: CGFloat = 2 + (rowHeight - 4 - keyHeight - dotsHeight) / 2
            for key in pinned {
                key.frame = CGRect(x: x, y: y, width: keyWidth, height: keyHeight)
                x += keyWidth + gap
            }
            x += gutter - gap
            let pagerWidth = keyWidth * 6 + gap * 5
            pager.frame = CGRect(x: x, y: 0, width: pagerWidth, height: rowHeight)
            layoutPagerKeys(keyWidth: keyWidth, keyHeight: keyHeight, y: y, pageWidth: pagerWidth, pages: pages)
            joystick?.frame = CGRect(x: x + pagerWidth + gutter, y: y, width: keyWidth, height: keyHeight)
            arrowPage?.frame = pager.frame
            layoutArrowPage(keyWidth: keyWidth, keyHeight: keyHeight, y: y)
            layoutDots(pagerFrame: pager.frame, y: y + keyHeight + 4)
        } else {
            // Larger Text: top row holds the pinned keys and the joystick, the second row the paging area.
            let top = pinned + [joystick].compactMap { $0 }
            let keyWidth = (w - inset * 2 - gap * CGFloat(top.count - 1)) / CGFloat(top.count)
            var x = inset
            for key in top {
                key.frame = CGRect(x: x, y: 3, width: keyWidth, height: rowHeight - 6)
                x += keyWidth + gap
            }
            let pageWidth = w - inset * 2
            let capWidth = (pageWidth - gap * 5) / 6
            pager.frame = CGRect(x: inset, y: rowHeight, width: pageWidth, height: rowHeight)
            layoutPagerKeys(keyWidth: capWidth, keyHeight: rowHeight - 6, y: 3, pageWidth: pageWidth, pages: pages)
            arrowPage?.frame = pager.frame
            layoutArrowPage(keyWidth: capWidth, keyHeight: rowHeight - 6, y: 3)
            layoutDots(pagerFrame: pager.frame, y: rowHeight * 2 - 6)
        }
    }

    private func layoutPagerKeys(keyWidth: CGFloat, keyHeight: CGFloat, y: CGFloat, pageWidth: CGFloat, pages: Int) {
        pager.contentSize = CGSize(width: pageWidth * CGFloat(pages), height: pager.bounds.height)
        for (pageIndex, caps) in pagerCaps.enumerated() {
            for (i, key) in caps.enumerated() {
                key.frame = CGRect(x: CGFloat(pageIndex) * pageWidth + CGFloat(i) * (keyWidth + gap), y: y, width: keyWidth, height: keyHeight)
            }
        }
        // Keep the current page after a rotation.
        pager.contentOffset = CGPoint(x: CGFloat(currentPage) * pageWidth, y: 0)
    }

    private func layoutArrowPage(keyWidth: CGFloat, keyHeight: CGFloat, y: CGFloat) {
        for (i, key) in arrowPageCaps.enumerated() {
            key.frame = CGRect(x: CGFloat(i) * (keyWidth + gap), y: y, width: keyWidth, height: keyHeight)
        }
    }

    private func layoutDots(pagerFrame: CGRect, y: CGFloat) {
        guard !dots.isEmpty else { return }
        let size: CGFloat = 4, spacing: CGFloat = 6
        let total = CGFloat(dots.count) * size + CGFloat(dots.count - 1) * spacing
        var x = pagerFrame.midX - total / 2
        for dot in dots {
            dot.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + spacing
        }
    }

    private func layoutPad() {
        let h = bounds.height
        let keyHeight = h - 12
        let keyWidth: CGFloat = 42
        let spacing: CGFloat = 4
        var x: CGFloat = 8
        for key in pinned {
            key.frame = CGRect(x: x, y: 6, width: keyWidth + 6, height: keyHeight)
            x += keyWidth + 6 + spacing
        }
        x += 4
        // Arrow cluster: inverted T, two rows.
        let arrowWidth: CGFloat = 36, arrowHeight = (h - 8) / 2
        let clusterWidth = arrowWidth * 3 + spacing * 2
        let clusterX = bounds.width - clusterWidth - 8
        if arrowCluster.count == 4 {
            let (left, down, up, right) = (arrowCluster[0], arrowCluster[1], arrowCluster[2], arrowCluster[3])
            up.frame = CGRect(x: clusterX + arrowWidth + spacing, y: 3, width: arrowWidth, height: arrowHeight - 1)
            left.frame = CGRect(x: clusterX, y: 3 + arrowHeight + 1, width: arrowWidth, height: arrowHeight - 1)
            down.frame = CGRect(x: clusterX + arrowWidth + spacing, y: 3 + arrowHeight + 1, width: arrowWidth, height: arrowHeight - 1)
            right.frame = CGRect(x: clusterX + (arrowWidth + spacing) * 2, y: 3 + arrowHeight + 1, width: arrowWidth, height: arrowHeight - 1)
        }
        let pagerWidth = max(0, clusterX - x - 8)
        pager.frame = CGRect(x: x, y: 0, width: pagerWidth, height: h)
        var cx: CGFloat = 0
        for key in pagerCaps.first ?? [] {
            key.frame = CGRect(x: cx, y: 6, width: keyWidth, height: keyHeight)
            cx += keyWidth + spacing
        }
        pager.contentSize = CGSize(width: cx, height: h)
    }

    private func layoutSlim() {
        let h = bounds.height
        let keyHeight = h - 6
        var x: CGFloat = 6
        for key in pinned {
            key.frame = CGRect(x: x, y: 3, width: 44, height: keyHeight)
            x += 48
        }
        var trailingX = bounds.width - 6
        for key in trailingPinned.reversed() {
            trailingX -= 44
            key.frame = CGRect(x: trailingX, y: 3, width: 44, height: keyHeight)
            trailingX -= 4
        }
        let pagerWidth = max(0, trailingX - x - 4)
        pager.frame = CGRect(x: x, y: 0, width: pagerWidth, height: h)
        var cx: CGFloat = 0
        for key in pagerCaps.first ?? [] {
            key.frame = CGRect(x: cx, y: 3, width: 40, height: keyHeight)
            cx += 44
        }
        pager.contentSize = CGSize(width: cx, height: h)
    }

    // MARK: Paging

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard style == .full, !isPad, scrollView.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        if page != currentPage, page >= 0, page < max(1, configuration.layout.pages.count) {
            currentPage = page
            updateDots()
            haptic(.tick)
        }
    }

    private func updateDots() {
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = i == currentPage ? KeyBarStyleKit.accent : KeyBarStyleKit.text3.withAlphaComponent(0.5)
        }
    }
}
#endif
