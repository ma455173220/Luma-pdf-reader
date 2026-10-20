import AppKit
import LumaCore

/// The bar that appears under the tabs for finding text in the current document.
final class SearchBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 36

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// Told when either option is turned on or off.
    var onOptionsChange: ((SearchOptions) -> Void)?

    /// Match case and whole words only: the reader's choices, kept between launches.
    var options: SearchOptions {
        SearchOptions(matchCase: caseButton.state == .on, wholeWords: wordButton.state == .on)
    }
    private let caseButton = NSButton()
    private let wordButton = NSButton()

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton(title: L("Done"), target: nil, action: nil)

    var query: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = L("Find in Document")
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(fieldChanged)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        func arrow(_ button: NSButton, _ symbol: String, _ title: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.toolTip = title
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = action
        }
        arrow(previousButton, "chevron.up", L("Previous"), #selector(previous))
        arrow(nextButton, "chevron.down", L("Next"), #selector(next))
        // Two small toggles before the field, as in other Mac apps' find bars.
        for (button, title, tip, key) in [(caseButton, "Aa", L("Match Case"), "LumaSearchMatchCase"),
                                          (wordButton, "W", L("Whole Words Only"), "LumaSearchWholeWords")] {
            button.title = title
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            button.target = self
            button.action = #selector(optionChanged)
        }
        doneButton.bezelStyle = .accessoryBarAction
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(close)

        let row = NSStackView(views: [caseButton, wordButton, field, countLabel, previousButton, nextButton, doneButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 260),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// For the benchmark's walk-through.
    func debugSetQuery(_ text: String) { field.stringValue = text }

    func setCount(_ text: String, hasMatches: Bool) {
        countLabel.stringValue = text
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    @objc private func fieldChanged() { onQueryChange?(field.stringValue) }

    @objc private func optionChanged() {
        UserDefaults.standard.set(caseButton.state == .on, forKey: "LumaSearchMatchCase")
        UserDefaults.standard.set(wordButton.state == .on, forKey: "LumaSearchWholeWords")
        onOptionsChange?(options)
    }

    /// For the benchmark's walk-through: sets the two options, as pressing them would (not kept).
    func debugSetOptions(_ options: SearchOptions) {
        caseButton.state = options.matchCase ? .on : .off
        wordButton.state = options.wholeWords ? .on : .off
    }
    @objc private func next() { onNext?() }
    @objc private func previous() { onPrevious?() }
    @objc private func close() { onClose?() }

    /// Return goes to the next match, Shift-Return to the previous one, Escape closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
