import AppKit

// MARK: - SparklineView

/// Draws a mini area chart from an array of Double values.
class SparklineView: NSView {
    var data: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor = .secondaryLabelColor
    var fillColor: NSColor = .secondaryLabelColor.withAlphaComponent(0.15)

    override func draw(_ dirtyRect: NSRect) {
        guard data.count >= 2 else { return }
        let maxVal = data.max() ?? 1
        guard maxVal > 0 else { return }

        let w = bounds.width
        let h = bounds.height
        let step = w / CGFloat(data.count - 1)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))

        for (i, val) in data.enumerated() {
            let x = CGFloat(i) * step
            let y = CGFloat(val / maxVal) * h
            path.line(to: NSPoint(x: x, y: y))
        }

        // Close the fill area
        path.line(to: NSPoint(x: CGFloat(data.count - 1) * step, y: 0))
        path.close()

        fillColor.setFill()
        path.fill()

        // Draw stroke on top (just the data line, not the bottom edge)
        let strokePath = NSBezierPath()
        strokePath.lineWidth = 1.0
        for (i, val) in data.enumerated() {
            let x = CGFloat(i) * step
            let y = CGFloat(val / maxVal) * h
            if i == 0 {
                strokePath.move(to: NSPoint(x: x, y: y))
            } else {
                strokePath.line(to: NSPoint(x: x, y: y))
            }
        }

        strokeColor.setStroke()
        strokePath.stroke()
    }

    override var isFlipped: Bool { false }
}

// MARK: - QuotaView

/// Displays Claude Code context usage, rate limit usage, and token rate in the sidebar.
class QuotaView: NSView {
    // --- Context row (top) ---
    private let contextLabel = NSTextField(labelWithString: "context")
    private let contextPercent = NSTextField(labelWithString: "")
    private let contextBar = NSView()
    private let contextFill = NSView()
    private let contextModel = NSTextField(labelWithString: "")
    private var contextFillWidth: NSLayoutConstraint?
    private var contextViews: [NSView] { [contextLabel, contextPercent, contextBar, contextModel] }

    // --- 5h row ---
    private let fiveHourLabel = NSTextField(labelWithString: "5h session")
    private let fiveHourPercent = NSTextField(labelWithString: "")
    private let fiveHourBar = NSView()
    private let fiveHourFill = NSView()
    private let fiveHourReset = NSTextField(labelWithString: "")
    private var fiveHourFillWidth: NSLayoutConstraint?

    // --- 7d row ---
    private let sevenDayLabel = NSTextField(labelWithString: "7d weekly")
    private let sevenDayPercent = NSTextField(labelWithString: "")
    private let sevenDayBar = NSView()
    private let sevenDayFill = NSView()
    private let sevenDayReset = NSTextField(labelWithString: "")
    private var sevenDayFillWidth: NSLayoutConstraint?

    private let separator = NSView()
    private let tokenRateLabel = NSTextField(labelWithString: "")
    private let sparklineView = SparklineView()

    private let resetFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setupSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        let colors = ThemeManager.shared.currentColors

        // --- Context row (top) ---
        configureLabel(contextLabel, size: 10, color: colors.secondaryText)
        configureLabel(contextPercent, size: 10, color: colors.secondaryText, alignment: .right, bold: true)
        configureBar(contextBar, fill: contextFill, colors: colors)
        configureLabel(contextModel, size: 9, color: colors.secondaryText.withAlphaComponent(0.6))
        contextViews.forEach { $0.isHidden = true }

        // --- 5h row ---
        configureLabel(fiveHourLabel, size: 10, color: colors.secondaryText)
        configureLabel(fiveHourPercent, size: 10, color: colors.secondaryText, alignment: .right, bold: true)
        configureBar(fiveHourBar, fill: fiveHourFill, colors: colors)
        configureLabel(fiveHourReset, size: 9, color: colors.secondaryText.withAlphaComponent(0.6))

        // --- 7d row ---
        configureLabel(sevenDayLabel, size: 10, color: colors.secondaryText)
        configureLabel(sevenDayPercent, size: 10, color: colors.secondaryText, alignment: .right, bold: true)
        configureBar(sevenDayBar, fill: sevenDayFill, colors: colors)
        configureLabel(sevenDayReset, size: 9, color: colors.secondaryText.withAlphaComponent(0.6))

        // --- Separator ---
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = colors.secondaryText.withAlphaComponent(0.2).cgColor
        addSubview(separator)

        // --- Token rate row ---
        configureLabel(tokenRateLabel, size: 9, color: colors.secondaryText.withAlphaComponent(0.6))
        tokenRateLabel.setContentHuggingPriority(.required, for: .horizontal)
        tokenRateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        sparklineView.translatesAutoresizingMaskIntoConstraints = false
        sparklineView.strokeColor = colors.secondaryText.withAlphaComponent(0.6)
        sparklineView.fillColor = colors.secondaryText.withAlphaComponent(0.15)
        addSubview(sparklineView)

        // --- Layout ---
        contextFillWidth = contextFill.widthAnchor.constraint(equalToConstant: 0)
        fiveHourFillWidth = fiveHourFill.widthAnchor.constraint(equalToConstant: 0)
        sevenDayFillWidth = sevenDayFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Context header row (top)
            contextLabel.topAnchor.constraint(equalTo: topAnchor),
            contextLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            contextPercent.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
            contextPercent.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: contextPercent.leadingAnchor, constant: -4),

            // Context bar
            contextBar.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 3),
            contextBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            contextBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextBar.heightAnchor.constraint(equalToConstant: 4),
            contextFill.leadingAnchor.constraint(equalTo: contextBar.leadingAnchor),
            contextFill.topAnchor.constraint(equalTo: contextBar.topAnchor),
            contextFill.bottomAnchor.constraint(equalTo: contextBar.bottomAnchor),
            contextFillWidth!,

            // Context model
            contextModel.topAnchor.constraint(equalTo: contextBar.bottomAnchor, constant: 2),
            contextModel.leadingAnchor.constraint(equalTo: leadingAnchor),

            // 5h header row
            fiveHourLabel.topAnchor.constraint(equalTo: contextModel.bottomAnchor, constant: 8),
            fiveHourLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            fiveHourPercent.centerYAnchor.constraint(equalTo: fiveHourLabel.centerYAnchor),
            fiveHourPercent.trailingAnchor.constraint(equalTo: trailingAnchor),
            fiveHourLabel.trailingAnchor.constraint(lessThanOrEqualTo: fiveHourPercent.leadingAnchor, constant: -4),

            // 5h bar
            fiveHourBar.topAnchor.constraint(equalTo: fiveHourLabel.bottomAnchor, constant: 3),
            fiveHourBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            fiveHourBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            fiveHourBar.heightAnchor.constraint(equalToConstant: 4),
            fiveHourFill.leadingAnchor.constraint(equalTo: fiveHourBar.leadingAnchor),
            fiveHourFill.topAnchor.constraint(equalTo: fiveHourBar.topAnchor),
            fiveHourFill.bottomAnchor.constraint(equalTo: fiveHourBar.bottomAnchor),
            fiveHourFillWidth!,

            // 5h reset
            fiveHourReset.topAnchor.constraint(equalTo: fiveHourBar.bottomAnchor, constant: 2),
            fiveHourReset.leadingAnchor.constraint(equalTo: leadingAnchor),

            // 7d header row
            sevenDayLabel.topAnchor.constraint(equalTo: fiveHourReset.bottomAnchor, constant: 8),
            sevenDayLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            sevenDayPercent.centerYAnchor.constraint(equalTo: sevenDayLabel.centerYAnchor),
            sevenDayPercent.trailingAnchor.constraint(equalTo: trailingAnchor),
            sevenDayLabel.trailingAnchor.constraint(lessThanOrEqualTo: sevenDayPercent.leadingAnchor, constant: -4),

            // 7d bar
            sevenDayBar.topAnchor.constraint(equalTo: sevenDayLabel.bottomAnchor, constant: 3),
            sevenDayBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sevenDayBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sevenDayBar.heightAnchor.constraint(equalToConstant: 4),
            sevenDayFill.leadingAnchor.constraint(equalTo: sevenDayBar.leadingAnchor),
            sevenDayFill.topAnchor.constraint(equalTo: sevenDayBar.topAnchor),
            sevenDayFill.bottomAnchor.constraint(equalTo: sevenDayBar.bottomAnchor),
            sevenDayFillWidth!,

            // 7d reset
            sevenDayReset.topAnchor.constraint(equalTo: sevenDayBar.bottomAnchor, constant: 2),
            sevenDayReset.leadingAnchor.constraint(equalTo: leadingAnchor),

            // Separator
            separator.topAnchor.constraint(equalTo: sevenDayReset.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            // Token rate row
            tokenRateLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5),
            tokenRateLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            tokenRateLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            sparklineView.leadingAnchor.constraint(equalTo: tokenRateLabel.trailingAnchor, constant: 6),
            sparklineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sparklineView.centerYAnchor.constraint(equalTo: tokenRateLabel.centerYAnchor),
            sparklineView.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private var hasContext = false

    /// Update the context window usage bar (called from the 5-second context timer).
    func updateContext(usage: ContextMonitor.ContextUsage?, tabName: String?) {
        hasContext = usage != nil
        if let usage = usage {
            contextViews.forEach { $0.isHidden = false }
            updateBar(
                percent: usage.percentage,
                label: contextPercent,
                fill: contextFill,
                widthConstraint: &contextFillWidth,
                bar: contextBar)
            let shortModel = usage.model
                .replacingOccurrences(of: "claude-", with: "")
                .components(separatedBy: "-20").first ?? usage.model
            if let name = tabName, !name.isEmpty {
                contextLabel.stringValue = "Context: \(name)"
            } else {
                contextLabel.stringValue = "Context"
            }
            contextModel.stringValue = shortModel
        } else {
            contextViews.forEach { $0.isHidden = true }
        }
        updateVisibility()
    }

    func update(snapshot: QuotaMonitor.QuotaSnapshot?, tokenRate: QuotaMonitor.TokenRate?,
                sparklineData: [Double], alwaysShowRate: Bool = false) {
        let hasQuota = snapshot != nil
            && (snapshot!.fiveHourUsed > 0 || snapshot!.sevenDayUsed > 0
                || snapshot!.fiveHourResetsAt != nil || snapshot!.sevenDayResetsAt != nil)
        let hasRate = tokenRate != nil && tokenRate!.tokensPerMinute > 0

        if let snap = snapshot, hasQuota {
            fiveHourLabel.isHidden = false
            fiveHourPercent.isHidden = false
            fiveHourBar.isHidden = false
            fiveHourReset.isHidden = false
            sevenDayLabel.isHidden = false
            sevenDayPercent.isHidden = false
            sevenDayBar.isHidden = false
            sevenDayReset.isHidden = false

            // If the reset time has passed, show 0% (quota has reset)
            let fivePct = hasReset(snap.fiveHourResetsAt) ? 0 : snap.fiveHourUsed
            updateBar(
                percent: fivePct,
                label: fiveHourPercent,
                fill: fiveHourFill,
                widthConstraint: &fiveHourFillWidth,
                bar: fiveHourBar)
            fiveHourReset.stringValue = resetString(for: snap.fiveHourResetsAt)

            let sevenPct = hasReset(snap.sevenDayResetsAt) ? 0 : snap.sevenDayUsed
            updateBar(
                percent: sevenPct,
                label: sevenDayPercent,
                fill: sevenDayFill,
                widthConstraint: &sevenDayFillWidth,
                bar: sevenDayBar)
            sevenDayReset.stringValue = resetString(for: snap.sevenDayResetsAt)
        } else {
            fiveHourLabel.isHidden = true
            fiveHourPercent.isHidden = true
            fiveHourBar.isHidden = true
            fiveHourReset.isHidden = true
            sevenDayLabel.isHidden = true
            sevenDayPercent.isHidden = true
            sevenDayBar.isHidden = true
            sevenDayReset.isHidden = true
        }

        // Show token rate if we have current data, sparkline history, or forced visible (Claude tabs)
        let showRate = hasRate || !sparklineData.isEmpty || alwaysShowRate
        if showRate {
            let rateValue = tokenRate?.tokensPerMinute ?? 0
            tokenRateLabel.stringValue = "\(formatTokenRate(rateValue)) tok/min"
            separator.isHidden = !(hasQuota || hasContext)
            tokenRateLabel.isHidden = false
            sparklineView.isHidden = false
        } else {
            separator.isHidden = true
            tokenRateLabel.isHidden = true
            sparklineView.isHidden = true
        }

        sparklineView.data = sparklineData
        updateVisibility()
    }

    private func updateVisibility() {
        let hasQuota = !fiveHourLabel.isHidden
        let hasRate = !tokenRateLabel.isHidden
        let hasSparkline = !sparklineView.isHidden
        isHidden = !hasContext && !hasQuota && !hasRate && !hasSparkline
    }

    func applyTheme(colors: ThemeColors) {
        let secondary = colors.secondaryText
        let dim = secondary.withAlphaComponent(0.6)

        for label in [contextLabel, fiveHourLabel, sevenDayLabel] {
            label.textColor = secondary
        }
        for label in [contextModel, fiveHourReset, sevenDayReset, tokenRateLabel] {
            label.textColor = dim
        }

        contextBar.layer?.backgroundColor = secondary.withAlphaComponent(0.2).cgColor
        fiveHourBar.layer?.backgroundColor = secondary.withAlphaComponent(0.2).cgColor
        sevenDayBar.layer?.backgroundColor = secondary.withAlphaComponent(0.2).cgColor
        separator.layer?.backgroundColor = secondary.withAlphaComponent(0.2).cgColor

        sparklineView.strokeColor = dim
        sparklineView.fillColor = secondary.withAlphaComponent(0.15)

        // Re-color percentage labels and fills based on current values
        if let snap = QuotaMonitor.shared.latest {
            fiveHourPercent.textColor = colorForPercentage(snap.fiveHourUsed)
            fiveHourFill.layer?.backgroundColor = colorForPercentage(snap.fiveHourUsed).cgColor
            sevenDayPercent.textColor = colorForPercentage(snap.sevenDayUsed)
            sevenDayFill.layer?.backgroundColor = colorForPercentage(snap.sevenDayUsed).cgColor
        }
    }

    // MARK: - Helpers

    private func configureLabel(_ label: NSTextField, size: CGFloat, color: NSColor,
                                alignment: NSTextAlignment = .left, bold: Bool = false) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = bold ? .monospacedDigitSystemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    private func configureBar(_ bar: NSView, fill: NSView, colors: ThemeColors) {
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = colors.secondaryText.withAlphaComponent(0.2).cgColor
        addSubview(bar)

        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 2
        bar.addSubview(fill)
    }

    private func updateBar(percent: Double, label: NSTextField, fill: NSView,
                           widthConstraint: inout NSLayoutConstraint?, bar: NSView) {
        let clamped = max(0, min(100, percent))
        label.stringValue = "\(Int(clamped.rounded()))%"

        let color = colorForPercentage(clamped)
        label.textColor = color
        fill.layer?.backgroundColor = color.cgColor

        widthConstraint?.isActive = false
        let fraction = CGFloat(clamped) / 100.0
        widthConstraint = fill.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: max(fraction, 0.001))
        widthConstraint?.isActive = true
    }

    private func colorForPercentage(_ pct: Double) -> NSColor {
        switch Int(pct) {
        case 0..<50: return NSColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 1.0)
        case 50..<75: return .systemYellow
        case 75..<90: return .systemOrange
        default: return .systemRed
        }
    }

    private func hasReset(_ date: Date?) -> Bool {
        guard let date = date else { return false }
        return date <= Date()
    }

    private func resetString(for date: Date?) -> String {
        guard let date = date else { return "" }
        if date <= Date() { return "" }
        return "resets \(resetFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func formatTokenRate(_ rate: Double) -> String {
        if rate >= 1_000_000 { return String(format: "%.1fM", rate / 1_000_000) }
        if rate >= 1_000 { return String(format: "%.1fk", rate / 1_000) }
        return String(format: "%.0f", rate)
    }
}
