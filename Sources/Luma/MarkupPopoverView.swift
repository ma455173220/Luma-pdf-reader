import AppKit
import LumaCore

/// The small panel that appears over selected text (to make a mark) or over an existing mark
/// (to change it).
///
/// For new text: a highlighter, an underline and a strikethrough button make the mark at once, in the colour that
/// is ringed; the colours only choose which (yellow until another is picked); a note can be added.
/// For an existing mark: a colour recolours it, the note can be changed, and it can be deleted.
final class MarkupPopoverView: NSView, NSTextViewDelegate {
    enum Mode {
        /// For new text, with the colour new marks get.
        case create(colour: MarkColour)
        /// For an existing mark, with its current colour and note.
        case edit(colour: MarkColour?, note: String)
        /// The document cannot take marks; the panel only says why.
        case blocked(String)
    }

    static let barHeight: CGFloat = 40
    static let noteHeight: CGFloat = 110

    /// New text: make a mark of this kind, in this colour, with this note.
    var onMark: ((MarkupAddition.Kind, MarkColour, String?) -> Void)?
    /// New text: the colour for new marks was changed. An existing mark: recolour it.
    var onColour: ((MarkColour) -> Void)?
    /// An existing mark: its note was changed.
    var onNote: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// Escape pressed while writing the note.
    var onEscape: (() -> Void)?
    /// The note's own undo, so that ⌘Z while writing takes back typing, not the last mark.
    private let noteUndo = UndoManager()
    /// The panel asks to be resized when the note area opens.
    var onResize: ((CGFloat) -> Void)?

    private let mode: Mode
    private var colour: MarkColour?
    private var dots: [ColourDot] = []
    private var noteView: NSTextView?
    private var noteScroll: NSScrollView?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create(let colour): self.colour = colour
        case .edit(let colour, _): self.colour = colour
        case .blocked: self.colour = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: MarkupPopoverView.width(for: mode), height: MarkupPopoverView.barHeight))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static func width(for mode: Mode) -> CGFloat {
        switch mode {
        // Three buttons that make a mark, the colours and the note button (one button wider since
        // strikethrough came in, which had pushed the note button out of sight).
        case .create: return 266
        case .edit: return 250
        case .blocked: return 330
        }
    }

    private func build() {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: MarkupPopoverView.barHeight)
        row.autoresizingMask = [.width]
        addSubview(row)

        if case .blocked(let reason) = mode {
            let label = NSTextField(wrappingLabelWithString: reason)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            row.addArrangedSubview(label)
            return
        }

        if case .create = mode {
            // The two buttons that make the mark are the panel's main ones: full strength, a size up.
            for (symbol, title, action) in [("highlighter", L("Highlight"), #selector(highlight)), ("underline", L("Underline"), #selector(underline)),
                                            ("strikethrough", L("Strikethrough"), #selector(strikeOut))] {
                let button = symbolButton(symbol, title, action)
                button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
                button.contentTintColor = .labelColor
                row.addArrangedSubview(button)
            }
            row.addArrangedSubview(divider())
        }
        for choice in MarkColour.allCases {
            let dot = ColourDot(colour: choice, isCurrent: choice == colour)
            dot.target = self
            dot.action = #selector(colourChosen(_:))
            dots.append(dot)
            row.addArrangedSubview(dot)
        }
        row.addArrangedSubview(divider())
        row.addArrangedSubview(symbolButton("text.bubble", L("Note"), #selector(openNote)))
        if case .edit = mode {
            row.addArrangedSubview(symbolButton("trash", L("Delete"), #selector(deleteMark)))
        }
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = title
        return button
    }

    @objc private func highlight() { mark(.highlight) }
    @objc private func underline() { mark(.underline) }
    @objc private func strikeOut() { mark(.strikeOut) }

    private func mark(_ kind: MarkupAddition.Kind) {
        onMark?(kind, colour ?? .yellow, noteView?.string)
    }

    @objc private func colourChosen(_ sender: ColourDot) {
        colour = sender.colour
        dots.forEach { $0.isCurrent = $0.colour == sender.colour }
        onColour?(sender.colour)
    }

    @objc private func deleteMark() {
        onDelete?()
    }

    @objc private func openNote() {
        guard noteView == nil else { return }
        let scroll = NSScrollView(frame: NSRect(x: 10, y: MarkupPopoverView.barHeight, width: bounds.width - 20, height: MarkupPopoverView.noteHeight - 40))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 12)
        text.autoresizingMask = [.width]
        text.delegate = self
        if case .edit(_, let note) = mode { text.string = note }
        scroll.documentView = text
        addSubview(scroll)
        let done = NSButton(title: L("Done"), target: self, action: #selector(finishNote))
        done.controlSize = .small
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        done.frame = NSRect(x: bounds.width - 70, y: MarkupPopoverView.barHeight + MarkupPopoverView.noteHeight - 36, width: 60, height: 24)
        addSubview(done)
        noteView = text
        noteScroll = scroll
        onResize?(MarkupPopoverView.barHeight + MarkupPopoverView.noteHeight)
        window?.makeFirstResponder(text)
    }

    /// 完成: for an existing mark, keeps the note; for new text, makes a highlight carrying it.
    @objc private func finishNote() {
        let text = noteView?.string ?? ""
        if case .create = mode { onMark?(.highlight, colour ?? .yellow, text) } else { onNote?(text) }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { noteUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onEscape?()
        return true
    }

    /// Opens the note area at once when an existing mark already has a note.
    func showNoteIfAny() {
        if case .edit(_, let note) = mode, !note.isEmpty { openNote() }
    }

    /// The note typed so far, if the note area is open.
    var noteText: String? { noteView?.string }

    /// The panel is going away without 完成 being pressed: a note that was typed or changed is kept anyway.
    func finishNoteIfChanged() {
        guard let text = noteView?.string else { return }
        var original = ""
        if case .edit(_, let note) = mode { original = note }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != original.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        finishNote()
    }
}

/// One colour choice: a filled circle, ringed when it is the colour in use.
private final class ColourDot: NSControl {
    let colour: MarkColour
    var isCurrent: Bool { didSet { needsDisplay = true } }

    init(colour: MarkColour, isCurrent: Bool) {
        self.colour = colour
        self.isCurrent = isCurrent
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolTip = [L("Yellow"), L("Red"), L("Green"), L("Blue")][colour.rawValue]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        colour.color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).stroke()
        if isCurrent {
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
