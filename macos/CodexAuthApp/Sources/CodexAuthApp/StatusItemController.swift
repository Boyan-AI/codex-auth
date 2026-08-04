import AppKit
import Combine
import SwiftUI

struct StatusItemSegment: Equatable {
    let text: String
    let tone: UsageTone
}

struct StatusItemPresentation: Equatable {
    /// 百分比底色保持左右各 7pt 内边距。
    static let capsuleHorizontalPadding: CGFloat = 14
    /// 状态项仅保留左右各 1pt 外边距，以缩短菜单栏占用。
    static let statusItemOuterPadding: CGFloat = 2

    let segments: [StatusItemSegment]
    let isLoading: Bool

    /// 根据账号实际返回的窗口生成菜单栏片段，缺失的 5 小时窗口不会占位。
    init(account: CodexAccount?, isLoading: Bool, resetCredits: ResetCreditsInfo? = nil) {
        self.isLoading = isLoading
        // 顶部状态栏只显示周用量百分比；reset 详情仅展示在账号展开行中。
        _ = resetCredits
        if account?.isAPIKey == true {
            self.segments = [StatusItemSegment(text: "KEY", tone: .unavailable)]
            return
        }
        self.segments = [
            StatusItemSegment(
                text: account?.usage.sevenDay.menuBarPercentText ?? "--",
                tone: account?.usage.sevenDay.menuBarUsageTone ?? .unavailable
            )
        ]
    }

    var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// 将多行状态压缩成系统状态栏按钮可稳定显示的单行文本。
    var statusBarButtonText: String {
        segments.map(\.text).joined(separator: "  ")
    }

    /// 计算系统按钮承载完整状态文本所需的宽度。
    var minimumStatusItemLength: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let textWidth = (statusBarButtonText as NSString).size(withAttributes: [.font: font]).width
        let maximumPercentWidth = ("100%" as NSString).size(withAttributes: [.font: font]).width
        return ceil(max(textWidth, maximumPercentWidth) + Self.capsuleHorizontalPadding + Self.statusItemOuterPadding)
    }

    /// 将额度胶囊稳定居中在状态项按钮内，使弹窗箭头始终指向可见内容中心。
    func horizontalOrigin(containerWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        max(0, floor((containerWidth - contentWidth) / 2))
    }

    /// 按实际片段数量计算从上到下的绘制原点，使单行和双行内容都整体垂直居中。
    func lineOrigins(containerHeight: CGFloat, textHeight: CGFloat, lineSpacing: CGFloat) -> [CGFloat] {
        guard !segments.isEmpty else {
            return []
        }
        let contentHeight = textHeight + CGFloat(segments.count - 1) * lineSpacing
        let bottomY = floor((containerHeight - contentHeight) / 2)
        return segments.indices.map { index in
            bottomY + CGFloat(segments.count - index - 1) * lineSpacing
        }
    }
}

@MainActor
final class StatusItemController: NSObject, ObservableObject {
    private let appState: AppState
    private let managementWindowController: ManagementWindowController
    private let statusItem: NSStatusItem
    private let statusItemView = QuotaStatusItemView(frame: NSRect(x: 0, y: 0, width: 78, height: NSStatusBar.system.thickness))
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        self.managementWindowController = ManagementWindowController(appState: appState)
        self.statusItem = NSStatusBar.system.statusItem(withLength: 78)
        super.init()
        configurePopover()
        configureStatusItemView()
        bindState()
        updateStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 1)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(closeMenu: { [weak self] in
                self?.closePopover()
            }, openManagement: { [weak self] section in
                self?.managementWindowController.show(section: section)
            })
                .environmentObject(appState)
                .frame(width: 420)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial)
        )
    }

    private func configureStatusItemView() {
        guard let button = statusItem.button else {
            return
        }
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.toolTip = "Codex Auth"
        button.target = self
        button.action = #selector(togglePopover(_:))

        statusItemView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusItemView)
        NSLayoutConstraint.activate([
            statusItemView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusItemView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusItemView.topAnchor.constraint(equalTo: button.topAnchor),
            statusItemView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    private func bindState() {
        appState.$state
            .combineLatest(appState.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        let presentation = StatusItemPresentation(
            account: appState.state?.activeAccount,
            isLoading: appState.isLoading,
            resetCredits: appState.state?.resetCredits
        )
        statusItem.length = presentation.minimumStatusItemLength
        // 自绘视图统一计算背景、文字和垂直位置，避免系统按钮默认基线造成视觉偏移。
        statusItemView.frame.size.width = presentation.minimumStatusItemLength
        statusItemView.presentation = presentation
        statusItemView.isHidden = false
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            stopOutsideClickMonitor()
            return
        }

        // 先隐藏独立管理窗口，避免激活 App 时把未关闭的功能窗口一并带到前台。
        managementWindowController.hideForPopover()
        // 菜单栏 App 可能仍处于非活动状态；先激活再显示，避免首个点击只用于唤醒窗口。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startOutsideClickMonitor()
        Task { @MainActor in
            await appState.refreshOnMenuOpen()
        }
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else {
                return event
            }
            if event.window == self.popover.contentViewController?.view.window {
                return event
            }
            if event.window == self.statusItem.button?.window {
                return event
            }
            self.closePopover()
            return event
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func closePopover() {
        guard popover.isShown else {
            stopOutsideClickMonitor()
            return
        }
        popover.performClose(nil)
        stopOutsideClickMonitor()
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}

private final class QuotaStatusItemView: NSView {
    var presentation = StatusItemPresentation(account: nil, isLoading: false) {
        didSet {
            needsDisplay = true
        }
    }

    private var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: presentation.minimumStatusItemLength, height: NSStatusBar.system.thickness)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHighlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 9, yRadius: 9).fill()
        }

        drawQuotaLines()
    }

    /// 绘制额度片段，并根据当前片段数量保持整体垂直居中。
    private func drawQuotaLines() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let lineSpacing: CGFloat = 10
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let capsuleVerticalPadding: CGFloat = presentation.segments.count == 1 ? 6 : 2
        let lineOrigins = presentation.lineOrigins(
            containerHeight: bounds.height,
            textHeight: textHeight,
            lineSpacing: lineSpacing
        )

        for (index, segment) in presentation.segments.enumerated() {
            let y = lineOrigins[index]
            let parts = splitQuotaText(segment.text)
            let prefixAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: statusBarLabelColor,
            ]
            let percentAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let prefixWidth = (parts.prefix as NSString).size(withAttributes: prefixAttributes).width
            let percentSize = (parts.percent as NSString).size(withAttributes: percentAttributes)
            let contentWidth = prefixWidth + ceil(percentSize.width) + StatusItemPresentation.capsuleHorizontalPadding
            let x = presentation.horizontalOrigin(containerWidth: bounds.width, contentWidth: contentWidth)
            (parts.prefix as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: prefixAttributes)
            let capsuleRect = NSRect(
                x: x + prefixWidth,
                y: y - capsuleVerticalPadding / 2,
                width: ceil(percentSize.width) + StatusItemPresentation.capsuleHorizontalPadding,
                height: textHeight + capsuleVerticalPadding
            )
            segment.tone.statusItemBackgroundColor(forActiveMenuBar: true).setFill()
            NSBezierPath(
                roundedRect: capsuleRect,
                xRadius: capsuleRect.height / 2,
                yRadius: capsuleRect.height / 2
            ).fill()
            (parts.percent as NSString).draw(
                at: NSPoint(
                    x: capsuleRect.minX + StatusItemPresentation.capsuleHorizontalPadding / 2,
                    y: y
                ),
                withAttributes: percentAttributes
            )
        }
    }

    private func splitQuotaText(_ text: String) -> (prefix: String, percent: String) {
        guard let spaceIndex = text.firstIndex(of: " ") else {
            return ("", text)
        }
        let prefix = String(text[...spaceIndex])
        let percent = String(text[text.index(after: spaceIndex)...])
        return (prefix, percent)
    }

    private var statusBarLabelColor: NSColor {
        NSColor.white.withAlphaComponent(0.68)
    }
}

private extension UsageTone {
    /// 返回与额度状态匹配的半透明胶囊底色，并适配菜单栏高亮背景。
    func statusItemBackgroundColor(forActiveMenuBar activeMenuBar: Bool) -> NSColor {
        switch self {
        case .available:
            return NSColor(calibratedRed: 0.24, green: 0.68, blue: 0.32, alpha: activeMenuBar ? 0.82 : 0.72)
        case .warning:
            return NSColor(calibratedRed: 0.90, green: 0.60, blue: 0.10, alpha: activeMenuBar ? 0.86 : 0.76)
        case .low:
            return NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.16, alpha: activeMenuBar ? 0.86 : 0.76)
        case .unavailable:
            return NSColor.white.withAlphaComponent(activeMenuBar ? 0.22 : 0.14)
        }
    }
}
