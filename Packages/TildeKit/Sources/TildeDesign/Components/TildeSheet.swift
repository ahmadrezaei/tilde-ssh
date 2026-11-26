import SwiftUI

/// Layout constants shared by every sheet and form. Mac sheets are denser than iPad ones (20 pt vs 16 pt gutters).
public enum TildeSheetMetrics {
    /// Gutter around the content, the title row and the action bar.
    public static var padding: CGFloat {
        #if os(macOS)
        20
        #else
        16
        #endif
    }

    /// Minimum height of one form row.
    public static var rowHeight: CGFloat {
        #if os(macOS)
        38
        #else
        46
        #endif
    }

    /// Width of the label column in a form row. Fixed, so the fields line up and no label is ever clipped.
    public static let labelWidth: CGFloat = 112

    /// Horizontal padding inside a form card.
    public static let rowInset: CGFloat = 14
}

/// How wide a Mac sheet is. iPad sheets take the size the system gives them.
public enum TildeSheetSize: Sendable {
    /// Forms, imports, pickers: 520 pt minimum, 560 pt ideal.
    case form
    /// Short confirmations (paste, password, link): 440 pt minimum, 480 pt ideal.
    case compact

    var minWidth: CGFloat { self == .form ? 520 : 440 }
    var idealWidth: CGFloat { self == .form ? 560 : 480 }
}

/// The scaffold every Tilde modal uses: a title row (with an optional subtitle), a scrolling body with a consistent
/// gutter, and a bottom action bar with the buttons right-aligned. Put `Cancel` and the primary action in `actions`
/// with `.tildeSheetSecondary` / `.tildeSheetPrimary` (or `TildeCancelButton` / `TildeDefaultButton`, which also bind
/// Esc and Return).
///
/// ```swift
/// TildeSheet("New Server", subtitle: "Saved to iCloud") {
///     TildeFormSection("Connection") {
///         TildeTextRow("Host", prompt: "hostname or IP", text: $host)
///     }
/// } actions: {
///     TildeCancelButton { dismiss() }
///     TildeDefaultButton("Save") { save() }
/// }
/// ```
public struct TildeSheet<Content: View, Leading: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let subtitleIsMono: Bool
    private let size: TildeSheetSize
    private let scrolls: Bool
    private let idealHeight: CGFloat?
    private let content: Content
    private let leading: Leading
    private let actions: Actions
    private var banner: AnyView?
    private var headerAccessory: AnyView?
    private var showsActionBar = true

    /// - Parameters:
    ///   - subtitle: a muted line under the title.
    ///   - subtitleIsMono: set it for hostnames and other machine values.
    ///   - size: the Mac width class.
    ///   - scrolls: `false` when the content manages its own scrolling (a list) or is short enough to size itself.
    ///   - idealHeight: the Mac height the sheet opens at. Scrolling sheets default to 560; non-scrolling ones size to their content unless you pass one.
    ///   - leading: optional views at the left of the action bar ("Choose File…", a progress indicator).
    public init(
        _ title: String,
        subtitle: String? = nil,
        subtitleIsMono: Bool = false,
        size: TildeSheetSize = .form,
        scrolls: Bool = true,
        idealHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsMono = subtitleIsMono
        self.size = size
        self.scrolls = scrolls
        self.idealHeight = idealHeight ?? (scrolls ? 560 : nil)
        self.content = content()
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(TildeColor.border)
            if scrolls {
                ScrollView {
                    content
                        .padding(TildeSheetMetrics.padding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let banner {
                banner
                    .padding(.horizontal, TildeSheetMetrics.padding)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TildeColor.bg)
            }
            if showsActionBar {
                Divider().overlay(TildeColor.border)
                actionBar
            }
        }
        .background(TildeColor.bg)
        .tint(TildeColor.accent)
        .tildeSheetFrame(size: size, idealHeight: idealHeight)
    }

    /// A message pinned above the action bar, visible however far the body is scrolled (a failed save).
    public func banner<Banner: View>(_ isPresented: Bool = true, @ViewBuilder _ banner: () -> Banner) -> TildeSheet {
        var copy = self
        copy.banner = isPresented ? AnyView(banner()) : nil
        return copy
    }

    /// A view at the trailing edge of the title row (an "Add" menu, a count).
    public func headerAccessory<Accessory: View>(@ViewBuilder _ accessory: () -> Accessory) -> TildeSheet {
        var copy = self
        copy.headerAccessory = AnyView(accessory())
        return copy
    }

    /// Hides the bottom action bar. Only for a sheet whose host already supplies one (the Mac `NavigationStack` sheets
    /// wrapped by the window's sheet host add their own Done button there).
    public func actionBar(_ isVisible: Bool) -> TildeSheet {
        var copy = self
        copy.showsActionBar = isVisible
        return copy
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            titleBlock
            if let headerAccessory { headerAccessory }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TildeSheetMetrics.padding)
        .padding(.vertical, TildeSheetMetrics.padding - 4)
        .background(TildeColor.surface)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .tildeText(17, weight: .bold, relativeTo: .title3)
                .foregroundStyle(TildeColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .modifier(SubtitleFont(isMono: subtitleIsMono))
                    .foregroundStyle(TildeColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, TildeSheetMetrics.padding)
        .padding(.vertical, 12)
        .background(TildeColor.surface)
    }
}

public extension TildeSheet where Leading == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        subtitleIsMono: Bool = false,
        size: TildeSheetSize = .form,
        scrolls: Bool = true,
        idealHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title, subtitle: subtitle, subtitleIsMono: subtitleIsMono, size: size, scrolls: scrolls, idealHeight: idealHeight,
            content: content, leading: { EmptyView() }, actions: actions)
    }
}

private struct SubtitleFont: ViewModifier {
    let isMono: Bool
    func body(content: Content) -> some View {
        if isMono { content.tildeMono(12, relativeTo: .caption) } else { content.tildeText(13, relativeTo: .subheadline) }
    }
}

private extension View {
    @ViewBuilder
    func tildeSheetFrame(size: TildeSheetSize, idealHeight: CGFloat?) -> some View {
        #if os(macOS)
        if let idealHeight {
            frame(minWidth: size.minWidth, idealWidth: size.idealWidth, minHeight: min(idealHeight, 380), idealHeight: idealHeight)
                .presentationSizing(.fitted)
        } else {
            frame(minWidth: size.minWidth, idealWidth: size.idealWidth)
                .presentationSizing(.fitted)
        }
        #else
        self
        #endif
    }
}

// MARK: - Action buttons

/// Compact sheet buttons: mint fill for the primary action, a neutral fill for the rest, red text for destructive ones.
public struct TildeSheetButtonStyle: ButtonStyle {
    public enum Role { case primary, secondary, destructive }

    private let role: Role
    @Environment(\.isEnabled) private var isEnabled

    public init(_ role: Role) { self.role = role }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tildeText(14, weight: role == .primary ? .bold : .semibold, relativeTo: .body)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minHeight: TildeSheetMetrics.rowHeight - 6)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(role == .primary ? Color.clear : TildeColor.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    private var foreground: Color {
        switch role {
        case .primary: Color(hex: 0x04201C)
        case .secondary: TildeColor.text
        case .destructive: TildeColor.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch role {
        case .primary: pressed ? TildeColor.accentStrong : TildeColor.accent
        case .secondary, .destructive: pressed ? TildeColor.surface3 : TildeColor.surface2
        }
    }
}

public extension ButtonStyle where Self == TildeSheetButtonStyle {
    static var tildeSheetPrimary: TildeSheetButtonStyle { TildeSheetButtonStyle(.primary) }
    static var tildeSheetSecondary: TildeSheetButtonStyle { TildeSheetButtonStyle(.secondary) }
    static var tildeSheetDestructive: TildeSheetButtonStyle { TildeSheetButtonStyle(.destructive) }
}

/// "Cancel": secondary look, bound to Esc.
public struct TildeCancelButton: View {
    private let title: String
    private let action: () -> Void

    public init(_ title: String = "Cancel", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(.tildeSheetSecondary)
            .keyboardShortcut(.cancelAction)
    }
}

/// The primary action: mint fill, bound to Return. Dims with `.disabled(_:)`.
public struct TildeDefaultButton: View {
    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(.tildeSheetPrimary)
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Form building blocks

/// A titled group of form rows in a card, with a footnote below. Rows are separated by hairlines automatically, and
/// each gets the standard inset and minimum height. The footnote wraps; it is never truncated.
public struct TildeFormSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let footerTint: Color
    private let content: Content

    public init(_ title: String? = nil, footer: String? = nil, footerTint: Color = TildeColor.text3, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.footerTint = footerTint
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .tildeSectionHeader()
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: content) { subviews in
                VStack(spacing: 0) {
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
                        subview
                            .padding(.horizontal, TildeSheetMetrics.rowInset)
                            .frame(maxWidth: .infinity, minHeight: TildeSheetMetrics.rowHeight, alignment: .leading)
                    }
                }
                .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: TildeRadius.card))
                .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(TildeColor.border, lineWidth: TildeSpacing.hairline))
            }
            if let footer {
                Text(footer)
                    .tildeText(12, relativeTo: .caption)
                    .foregroundStyle(footerTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Label  | field`: a fixed-width label column and the field filling the rest, with an optional validation line under
/// the field. Build the field with `TildeTextField`, a `Picker` with `.labelsHidden()`, or anything else.
public struct TildeFieldRow<Field: View>: View {
    private let label: String
    private let issue: String?
    private let field: Field

    public init(_ label: String, issue: String? = nil, @ViewBuilder field: () -> Field) {
        self.label = label
        self.issue = issue
        self.field = field()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .tildeText(13, relativeTo: .body)
                    .foregroundStyle(TildeColor.text2)
                    .lineLimit(1)
                    .frame(width: TildeSheetMetrics.labelWidth, alignment: .leading)
                    .accessibilityHidden(true)
                field
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let issue {
                TildeIssueText(issue)
                    .padding(.leading, TildeSheetMetrics.labelWidth + 12)
                    .padding(.bottom, 6)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A labelled single-line text row: the label sits in the label column and `prompt` is the greyed placeholder inside
/// the field, so the two never repeat each other.
public struct TildeTextRow: View {
    private let label: String
    private let prompt: String
    private let issue: String?
    private let isMono: Bool
    private let isSecure: Bool
    @Binding private var text: String

    public init(_ label: String, prompt: String = "", text: Binding<String>, isMono: Bool = true, isSecure: Bool = false, issue: String? = nil) {
        self.label = label
        self.prompt = prompt
        self.issue = issue
        self.isMono = isMono
        self.isSecure = isSecure
        self._text = text
    }

    public var body: some View {
        TildeFieldRow(label, issue: issue) {
            TildeTextField(label, prompt: prompt, text: $text, isMono: isMono, isSecure: isSecure)
        }
    }
}

/// The bare field: no title, an explicit prompt, no border (the card around it is the container). Mono by default,
/// with autocorrect and auto-capitalisation off.
public struct TildeTextField: View {
    private let label: String
    private let prompt: String
    private let isMono: Bool
    private let isSecure: Bool
    @Binding private var text: String

    public init(_ label: String, prompt: String = "", text: Binding<String>, isMono: Bool = true, isSecure: Bool = false) {
        self.label = label
        self.prompt = prompt
        self.isMono = isMono
        self.isSecure = isSecure
        self._text = text
    }

    public var body: some View {
        let promptText = Text(prompt).foregroundStyle(TildeColor.text3)
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: promptText)
            } else {
                TextField("", text: $text, prompt: promptText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        }
        .textFieldStyle(.plain)
        .modifier(FieldFont(isMono: isMono))
        .foregroundStyle(TildeColor.text)
        .labelsHidden()
        .accessibilityLabel(label)
        .frame(maxWidth: .infinity, minHeight: TildeSheetMetrics.rowHeight - 4, alignment: .leading)
    }
}

private struct FieldFont: ViewModifier {
    let isMono: Bool
    func body(content: Content) -> some View {
        if isMono { content.tildeMono(14) } else { content.tildeText(14) }
    }
}

/// A labelled pop-up menu row.
public struct TildePickerRow<Selection: Hashable, Options: View>: View {
    private let label: String
    private let issue: String?
    @Binding private var selection: Selection
    private let options: Options

    public init(_ label: String, selection: Binding<Selection>, issue: String? = nil, @ViewBuilder options: () -> Options) {
        self.label = label
        self.issue = issue
        self._selection = selection
        self.options = options()
    }

    public var body: some View {
        TildeFieldRow(label, issue: issue) {
            Picker(label, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A full-width tappable row for an action inside a form card ("Test connection", "New group…").
public struct TildeActionRow<Trailing: View>: View {
    public enum Tone { case accent, neutral, danger }

    private let title: String
    private let systemImage: String?
    private let tone: Tone
    private let action: () -> Void
    private let trailing: Trailing

    public init(_ title: String, systemImage: String? = nil, tone: Tone = .accent, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.action = action
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
                Spacer(minLength: 8)
                trailing
            }
            .tildeText(14, weight: .medium, relativeTo: .body)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: TildeSheetMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch tone {
        case .accent: TildeColor.accent
        case .neutral: TildeColor.text
        case .danger: TildeColor.danger
        }
    }
}

public extension TildeActionRow where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil, tone: Tone = .accent, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, tone: tone, action: action, trailing: { EmptyView() })
    }
}

/// A switch row: the label (and an optional detail line that wraps) on the left, the switch on the right.
public struct TildeToggleRow: View {
    private let title: String
    private let detail: String?
    @Binding private var isOn: Bool

    public init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).tildeText(14, relativeTo: .body).foregroundStyle(TildeColor.text)
                if let detail {
                    Text(detail).tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(TildeColor.accentStrong)
        }
        .padding(.vertical, detail == nil ? 0 : 6)
    }
}

/// A read-only `Label | value` row (mono value by default).
public struct TildeValueRow: View {
    private let label: String
    private let value: String
    private let isMono: Bool

    public init(_ label: String, value: String, isMono: Bool = true) {
        self.label = label
        self.value = value
        self.isMono = isMono
    }

    public var body: some View {
        TildeFieldRow(label) {
            Text(value)
                .modifier(FieldFont(isMono: isMono))
                .foregroundStyle(TildeColor.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        }
    }
}

/// A validation message under a field.
public struct TildeIssueText: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .tildeText(12, relativeTo: .caption)
            .foregroundStyle(TildeColor.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline message with a tinted card: warnings above a form, errors from a failed action, success lines.
public struct TildeNotice: View {
    public enum Tone { case danger, warning, success, info }

    private let text: String
    private let tone: Tone
    private let systemImage: String?

    public init(_ text: String, tone: Tone, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage ?? defaultImage).foregroundStyle(color).accessibilityHidden(true)
            Text(text)
                .tildeText(13, relativeTo: .subheadline)
                .foregroundStyle(tone == .info ? TildeColor.text2 : TildeColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TildeSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: TildeRadius.card))
        .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(color.opacity(0.35), lineWidth: TildeSpacing.hairline))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .danger: TildeColor.danger
        case .warning: TildeColor.warn
        case .success: TildeColor.ok
        case .info: TildeColor.info
        }
    }

    private var defaultImage: String {
        switch tone {
        case .danger, .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }
}

#Preview("TildeSheet") {
    @Previewable @State var name = ""
    @Previewable @State var host = "10.0.1.12"
    @Previewable @State var sync = true
    TildeSheet("New Server", subtitle: "Saved to your iCloud database") {
        VStack(alignment: .leading, spacing: TildeSpacing.l) {
            TildeFormSection("Connection", footer: "Nothing is stored. You are asked at every connection, and the password never leaves this device.") {
                TildeTextRow("Name", prompt: "prod-api-01", text: $name)
                TildeTextRow("Host", prompt: "hostname or IP", text: $host, issue: "Enter a hostname or IP address.")
                TildeToggleRow("Sync with iCloud", detail: "Appears on your other devices.", isOn: $sync)
            }
            TildeNotice("This key is only 1024 bits.", tone: .warning)
        }
    } actions: {
        TildeCancelButton {}
        TildeDefaultButton("Save") {}
    }
    .frame(width: 560, height: 560)
}
