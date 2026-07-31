@preconcurrency import AppKit

@MainActor
final class RealtimeApplicationTableCellView: NSTableCellView {
    private let primaryTextField = NSTextField(labelWithString: "")
    private let secondaryTextField = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        primaryTextField.usesSingleLineMode = true
        primaryTextField.lineBreakMode = .byTruncatingTail
        primaryTextField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        secondaryTextField.usesSingleLineMode = true
        secondaryTextField.lineBreakMode = .byTruncatingTail
        secondaryTextField.textColor = .secondaryLabelColor
        secondaryTextField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.addArrangedSubview(primaryTextField)
        contentStack.addArrangedSubview(secondaryTextField)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func configure(
        primary: String,
        secondary: String?,
        alignment: NSTextAlignment,
        primaryFont: NSFont,
        secondaryFont: NSFont,
        accessibilityLabel: String,
        toolTip: String? = nil
    ) {
        primaryTextField.stringValue = primary
        primaryTextField.alignment = alignment
        primaryTextField.font = primaryFont
        secondaryTextField.stringValue = secondary ?? ""
        secondaryTextField.alignment = alignment
        secondaryTextField.font = secondaryFont
        secondaryTextField.isHidden = secondary == nil
        contentStack.alignment = alignment == .right ? .trailing : .leading
        setAccessibilityLabel(accessibilityLabel)
        self.toolTip = toolTip
    }
}
