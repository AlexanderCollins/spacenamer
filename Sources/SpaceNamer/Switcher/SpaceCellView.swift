import AppKit
import SpaceNamerCore

/// One Space in the switcher list.
final class SpaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SpaceCell")
    static let height: CGFloat = 44
    private static let maximumIcons = 6

    private let badge = BadgeView()
    private let agentDot = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let iconStack = NSStackView()
    private let accessoryLabel = NSTextField(labelWithString: "")
    private var titleText = ""
    private var titleRanges: [NSRange] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryLabel.alignment = .right
        accessoryLabel.setContentHuggingPriority(.required, for: .horizontal)
        accessoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconStack.orientation = .horizontal
        iconStack.spacing = 3
        iconStack.setContentHuggingPriority(.required, for: .horizontal)
        iconStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, agentDot])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        agentDot.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleRow, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [badge, text, NSView(), iconStack, accessoryLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: badge)
        row.setCustomSpacing(12, after: iconStack)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        title: String,
        ranges: [NSRange],
        subtitle: String?,
        space: Space,
        isCurrent: Bool,
        accessory: String?,
        apps: [NSRunningApplication],
        agent: DesktopAgentStatus?
    ) {
        titleText = title
        titleRanges = ranges
        badge.text = space.position.map(String.init)
        badge.isFullscreen = space.kind == .fullscreen
        badge.isCurrent = isCurrent
        // An agent's state leads the subtitle, after a dot in its colour by the name.
        let subtitle = [agent.map(AgentStyle.describe), subtitle].compactMap { $0 }.joined(separator: " — ")
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        agentDot.image = agent.map { AgentStyle.dot($0.state) }
        agentDot.isHidden = agent == nil
        accessoryLabel.stringValue = accessory ?? ""
        accessoryLabel.isHidden = accessory == nil

        iconStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for app in apps.prefix(Self.maximumIcons) {
            guard let icon = app.icon else { continue }
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.toolTip = app.localizedName
            view.widthAnchor.constraint(equalToConstant: 18).isActive = true
            view.heightAnchor.constraint(equalToConstant: 18).isActive = true
            iconStack.addArrangedSubview(view)
        }
        iconStack.isHidden = iconStack.arrangedSubviews.isEmpty

        setAccessibilityLabel([title, subtitle.isEmpty ? nil : subtitle, isCurrent ? "current" : nil].compactMap { $0 }.joined(separator: ", "))
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        badge.isOnSelection = selected

        let title = NSMutableAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: primary,
        ])
        for range in titleRanges where NSMaxRange(range) <= title.length {
            title.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: range)
        }
        titleLabel.attributedStringValue = title
        subtitleLabel.textColor = secondary
        accessoryLabel.textColor = secondary
    }
}

/// Display name above that display's Spaces when more than one display is connected.
final class HeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String) {
        label.stringValue = title.uppercased()
    }
}
