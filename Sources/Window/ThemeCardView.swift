import AppKit

/// A card that renders a mini terminal preview using a theme's actual colors.
class ThemeCardView: NSView {
    let themeName: String
    let themePath: String?  // nil = System Default

    var isSelectedTheme: Bool = false {
        didSet { updateBorder() }
    }

    var onSelect: ((ThemeCardView) -> Void)?

    private var cachedScheme: TerminalColorScheme?
    private var schemeParsed = false

    private let nameLabel = NSTextField(labelWithString: "")
    private let previewView: ThemePreviewView

    init(name: String, path: String?) {
        self.themeName = name
        self.themePath = path
        self.previewView = ThemePreviewView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        updateBorder()

        // Parse theme and pass to preview
        if let path = path {
            cachedScheme = TerminalColorScheme.parse(from: path)
        }
        previewView.scheme = cachedScheme
        previewView.isSystemDefault = (path == nil)

        // Preview area
        previewView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewView)

        // Name label
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: topAnchor),
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),

            nameLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            nameLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateBorder() {
        if isSelectedTheme {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
    }

    override func updateLayer() {
        super.updateLayer()
        updateBorder()
    }
}

// MARK: - Preview View (draws the mini terminal)

private class ThemePreviewView: NSView {
    var scheme: TerminalColorScheme?
    var isSystemDefault = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor
        let fg: NSColor
        let palette: [NSColor]

        if let scheme {
            bg = scheme.background
            fg = scheme.foreground
            palette = scheme.palette
        } else if isSystemDefault {
            bg = NSColor.windowBackgroundColor
            fg = NSColor.labelColor
            palette = []
        } else {
            bg = NSColor(white: 0.12, alpha: 1)
            fg = NSColor(white: 0.85, alpha: 1)
            palette = []
        }

        // Fill background
        bg.setFill()
        NSBezierPath(rect: bounds).fill()

        let monoFont = NSFont(name: "SF Mono", size: 10)
            ?? NSFont(name: "Menlo", size: 10)
            ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let green  = palette.count > 2 ? palette[2] : NSColor(red: 0, green: 0.8, blue: 0, alpha: 1)
        let red    = palette.count > 1 ? palette[1] : NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)
        let cyan   = palette.count > 6 ? palette[6] : NSColor(red: 0, green: 0.8, blue: 0.8, alpha: 1)
        let blue   = palette.count > 4 ? palette[4] : NSColor(red: 0, green: 0, blue: 0.8, alpha: 1)
        let yellow = palette.count > 3 ? palette[3] : NSColor(red: 0.8, green: 0.8, blue: 0, alpha: 1)
        let dim    = palette.count > 8 ? palette[8] : fg.withAlphaComponent(0.4)

        let lineHeight: CGFloat = 13
        let x: CGFloat = 6
        let y: CGFloat = 5

        drawParts([("~ ", green), ("$ ", fg), ("ls -la", cyan)],
                  font: monoFont, x: x, y: y)

        drawParts([("drwxr-xr-x ", dim), ("5 ", blue), ("user", yellow)],
                  font: monoFont, x: x, y: y + lineHeight)

        drawParts([("error: ", red), ("something", fg)],
                  font: monoFont, x: x, y: y + lineHeight * 2)

        let promptParts: [(String, NSColor)] = [("~ ", green), ("$ ", fg)]
        drawParts(promptParts, font: monoFont, x: x, y: y + lineHeight * 3)

        // Cursor block
        let cursorX = x + measureWidth(promptParts, font: monoFont)
        let cursorRect = NSRect(x: cursorX, y: y + lineHeight * 3, width: 7, height: lineHeight)
        green.withAlphaComponent(0.6).setFill()
        NSBezierPath(rect: cursorRect).fill()
    }

    private func drawParts(_ parts: [(String, NSColor)], font: NSFont, x: CGFloat, y: CGFloat) {
        var cx = x
        for (text, color) in parts {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str = NSAttributedString(string: text, attributes: attrs)
            str.draw(at: NSPoint(x: cx, y: y))
            cx += str.size().width
        }
    }

    private func measureWidth(_ parts: [(String, NSColor)], font: NSFont) -> CGFloat {
        parts.reduce(0) { sum, part in
            let attrs: [NSAttributedString.Key: Any] = [.font: part.1, .foregroundColor: part.1]
            return sum + NSAttributedString(string: part.0, attributes: [.font: NSFont(name: "SF Mono", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)]).size().width
        }
    }
}
