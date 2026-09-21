import AppKit
import CodexQuotaCore
import Foundation

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverController = QuotaPopoverViewController()
    private var currentState: QuotaState = .loading
    private var refreshInterval: RefreshIntervalOption = .oneMinute
    private var outsideClickMonitor: Any?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: 56)
        super.init()
        statusItem.isVisible = false

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = popoverController
        popoverController.onPreferredContentSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
        _ = popoverController.view
        popover.contentSize = popoverController.preferredContentSize

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "点击查看 Codex 额度详情"
        }
    }

    func configureActions(
        onRefresh: @escaping () -> Void,
        onIntervalChanged: @escaping (RefreshIntervalOption) -> Void,
        onQuit: @escaping () -> Void
    ) {
        popoverController.onRefresh = onRefresh
        popoverController.onIntervalChanged = { [weak self] option in
            self?.refreshInterval = option
            onIntervalChanged(option)
        }
        popoverController.onQuit = onQuit
    }

    func show(
        state: QuotaState,
        refreshInterval: RefreshIntervalOption
    ) {
        update(state: state, refreshInterval: refreshInterval)
        statusItem.isVisible = true
    }

    func hide() {
        closePopover()
        statusItem.isVisible = false
    }

    func update(
        state: QuotaState,
        refreshInterval: RefreshIntervalOption
    ) {
        currentState = state
        self.refreshInterval = refreshInterval
        guard let button = statusItem.button else { return }

        switch state {
        case .loading:
            setSingleIndicator(percent: nil, on: button)
            button.setAccessibilityLabel("Codex 额度正在读取，点击查看详情")
        case let .available(snapshot):
            if let fiveHour = snapshot.fiveHour {
                setDualIndicator(
                    fiveHourPercent: fiveHour.remainingPercent,
                    weeklyPercent: snapshot.weekly.remainingPercent,
                    on: button
                )
                button.setAccessibilityLabel(
                    "Codex 5小时额度剩余 \(fiveHour.remainingPercent)%，周额度剩余 \(snapshot.weekly.remainingPercent)%，点击查看详情"
                )
            } else {
                setSingleIndicator(percent: snapshot.weekly.remainingPercent, on: button)
                button.setAccessibilityLabel(
                    "Codex 周额度剩余 \(snapshot.weekly.remainingPercent)%，点击查看详情"
                )
            }
        case let .unavailable(message):
            setSingleIndicator(percent: nil, on: button)
            button.setAccessibilityLabel("Codex 额度读取失败：\(message)，点击查看详情")
        }

        if popover.isShown {
            updatePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
            return
        }

        updatePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        stopOutsideClickMonitor()
    }

    private func updatePopover() {
        popoverController.update(
            state: currentState,
            interval: refreshInterval
        )
        popover.contentSize = popoverController.preferredContentSize
    }

    private func setSingleIndicator(percent: Int?, on button: NSStatusBarButton) {
        let width = CGFloat(QuotaPresentation.indicatorWidth(for: percent))
        statusItem.length = width
        button.image = drawSingleIndicator(percent: percent)
    }

    private func setDualIndicator(
        fiveHourPercent: Int,
        weeklyPercent: Int,
        on button: NSStatusBarButton
    ) {
        let width = CGFloat(QuotaPresentation.dualIndicatorWidth(
            fiveHourPercent: fiveHourPercent,
            weeklyPercent: weeklyPercent
        ))
        statusItem.length = width
        button.image = drawDualIndicator(
            fiveHourPercent: fiveHourPercent,
            weeklyPercent: weeklyPercent,
            width: width
        )
    }

    private func drawSingleIndicator(percent: Int?) -> NSImage {
        let size = NSSize(
            width: CGFloat(QuotaPresentation.indicatorWidth(for: percent)),
            height: 16
        )
        let image = NSImage(size: size, flipped: false) { rect in
            let activeColor = percent.map { self.color(for: $0) } ?? NSColor.tertiaryLabelColor
            let filledCount = percent.map(QuotaPresentation.filledSegmentCount) ?? 0
            let barWidth: CGFloat = 3
            let barHeight: CGFloat = 6
            let spacing: CGFloat = 2
            let startX: CGFloat = 1
            let startY = (rect.height - barHeight) / 2

            for index in 0..<5 {
                let x = startX + CGFloat(index) * (barWidth + spacing)
                let barRect = NSRect(x: x, y: startY, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
                (index < filledCount ? activeColor : NSColor.tertiaryLabelColor).setFill()
                path.fill()
            }

            let text = percent.map { "\($0)%" } ?? "--%"
            let textFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: activeColor,
            ]
            let textSize = text.size(withAttributes: attributes)
            let textPoint = NSPoint(
                x: 29,
                y: (rect.height - textSize.height) / 2
            )
            text.draw(at: textPoint, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawDualIndicator(
        fiveHourPercent: Int,
        weeklyPercent: Int,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            self.drawDualRow(
                percent: fiveHourPercent,
                centerY: 15
            )
            self.drawDualRow(
                percent: weeklyPercent,
                centerY: 5
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawDualRow(
        percent: Int,
        centerY: CGFloat
    ) {
        let activeColor = color(for: percent)
        let filledCount = QuotaPresentation.filledSegmentCount(for: percent)
        let barWidth: CGFloat = 3
        let barHeight: CGFloat = 4
        let spacing: CGFloat = 2
        let startX: CGFloat = 1
        let startY = centerY - barHeight / 2

        for index in 0..<5 {
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let barRect = NSRect(x: x, y: startY, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            (index < filledCount ? activeColor : NSColor.tertiaryLabelColor).setFill()
            path.fill()
        }

        let text = "\(percent)%"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: activeColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 29, y: centerY - textSize.height / 2),
            withAttributes: attributes
        )
    }

private func color(for percent: Int) -> NSColor {
    return .labelColor
}
}
