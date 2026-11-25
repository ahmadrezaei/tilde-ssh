#if os(iOS)
import TildeDesign
import UIKit

/// Colours and fonts of the key bar, from the design tokens (docs/DESIGN.md section 2.2 and 5.2).
@MainActor
enum KeyBarStyleKit {
    static let keyFill = UIColor(TildeColor.surface2)
    static let keyFillPressed = UIColor(TildeColor.surface3)
    static let border = UIColor(TildeColor.border)
    static let text = UIColor(TildeColor.text)
    static let text2 = UIColor(TildeColor.text2)
    static let text3 = UIColor(TildeColor.text3)
    static let accent = UIColor(TildeColor.accent)
    static let accentSoft = UIColor(TildeColor.accentSoft)
    static let danger = UIColor(TildeColor.danger)

    /// SF Mono, scaled with Dynamic Type up to a limit so the labels stay in their keys.
    static func labelFont(size: CGFloat = 14, weight: UIFont.Weight = .medium, maximum: CGFloat = 19) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight), maximumPointSize: maximum)
    }

    static func alternateFont() -> UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedSystemFont(ofSize: 9, weight: .regular), maximumPointSize: 12)
    }
}

/// One cell of a `KeyPopoverView`.
struct PopoverItem {
    var label: String
    var caption: String?
    var accessibilityLabel: String
}

/// A floating picker above a key: the two characters of a key with a flick alternate, the Ctrl combo grid, or the
/// arrow bubble of the joystick. The finger that opened it keeps driving it (`select(at:)`), like the iOS
/// long-press accent picker. It is added to the app window, above the keyboard, so it can extend over the terminal.
@MainActor
final class KeyPopoverView: UIView {
    private let items: [PopoverItem]
    private let columns: Int
    private var cellFrames: [CGRect] = []
    private(set) var selectedIndex: Int?
    private let defaultSelection: Int?
    private let cellSize = CGSize(width: 46, height: 44)
    private let inset: CGFloat = 6

    /// - Parameter initialSelection: index highlighted before the finger moves.
    init(items: [PopoverItem], columns: Int, initialSelection: Int? = nil) {
        self.items = items
        self.columns = max(1, columns)
        self.selectedIndex = initialSelection
        self.defaultSelection = initialSelection
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(TildeColor.surface)
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.borderColor = KeyBarStyleKit.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        let rows = (items.count + self.columns - 1) / self.columns
        let size = CGSize(
            width: CGFloat(self.columns) * cellSize.width + inset * 2,
            height: CGFloat(rows) * cellSize.height + inset * 2
        )
        bounds = CGRect(origin: .zero, size: size)
        for index in items.indices {
            let col = index % self.columns, row = index / self.columns
            cellFrames.append(CGRect(x: inset + CGFloat(col) * cellSize.width, y: inset + CGFloat(row) * cellSize.height,
                                     width: cellSize.width, height: cellSize.height))
        }
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the popover centred above `anchor` (a rect in `window` coordinates), clamped to the window.
    func present(in window: UIWindow, above anchor: CGRect) {
        var x = anchor.midX - bounds.width / 2
        x = min(max(x, 6), window.bounds.width - bounds.width - 6)
        let y = max(window.safeAreaInsets.top + 4, anchor.minY - bounds.height - 8)
        frame = CGRect(x: x, y: y, width: bounds.width, height: bounds.height)
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        window.addSubview(self)
        UIView.animate(withDuration: 0.12, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.transform = .identity
        }
        setNeedsDisplay()
    }

    func dismiss() {
        UIView.animate(withDuration: 0.08, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }

    /// Highlights the cell under `point` (in this view's superview coordinates). Returns true when the selection changed.
    ///
    /// A single-row popover always has a selection (it falls back to the initial one); a grid selects nothing while
    /// the finger is outside it, so letting go there cancels.
    @discardableResult
    func select(atSuperviewPoint point: CGPoint) -> Bool {
        let p = convert(point, from: superview)
        let rows = (items.count + columns - 1) / columns
        var target: Int?
        if p.x >= inset - 14, p.x <= bounds.width - inset + 14 {
            let col = min(max(Int(((p.x - inset) / cellSize.width).rounded(.down)), 0), columns - 1)
            if rows == 1 {
                target = col < items.count ? col : nil
            } else if p.y <= bounds.height {
                let row = min(max(Int(((p.y - inset) / cellSize.height).rounded(.down)), 0), rows - 1)
                let index = row * columns + col
                target = index < items.count ? index : nil
            }
        }
        if rows == 1, target == nil { target = defaultSelection }
        guard target != selectedIndex else { return false }
        selectedIndex = target
        setNeedsDisplay()
        return true
    }

    override func draw(_ rect: CGRect) {
        for (index, item) in items.enumerated() {
            let frame = cellFrames[index]
            if index == selectedIndex {
                KeyBarStyleKit.accent.setFill()
                UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 8).fill()
            }
            let selected = index == selectedIndex
            let color = selected ? UIColor(TildeColor.bg) : KeyBarStyleKit.text
            let font = UIFont.monospacedSystemFont(ofSize: item.label.count > 2 ? 14 : 20, weight: .medium)
            let label = NSAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: color])
            let size = label.size()
            label.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 - (item.caption == nil ? 0 : 4)))
            if let caption = item.caption {
                let cap = NSAttributedString(string: caption, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                    .foregroundColor: selected ? UIColor(TildeColor.bg).withAlphaComponent(0.7) : KeyBarStyleKit.text3,
                ])
                let capSize = cap.size()
                cap.draw(at: CGPoint(x: frame.midX - capSize.width / 2, y: frame.maxY - capSize.height - 5))
            }
        }
    }
}
#endif
