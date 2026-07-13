import AppKit
import CoreGraphics
import Foundation

private let codexBundleIdentifier = "com.openai.codex"
private let statusItemAutosaveName = "codex-quota-menu"
private let overlayModePreferenceKey = "UseOverlayMenuBar"
private let overlayRightInsetPreferenceKey = "OverlayRightInset"

private struct AuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    let tokens: Tokens
}

private struct UsageResponse: Decodable {
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetAt: TimeInterval?
            let durationSeconds: TimeInterval?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case durationSeconds = "limit_window_seconds"
            }
        }

        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct QuotaSnapshot {
    let fiveHourRemainingPercent: Double?
    let weeklyRemainingPercent: Double?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let updatedAt: Date
}

private enum QuotaError: LocalizedError {
    case authMissing
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .authMissing:
            "找不到 Codex 登录信息"
        case .invalidResponse:
            "额度响应格式无效"
        case let .http(code):
            "额度接口返回 HTTP \(code)"
        }
    }
}

private final class QuotaService {
    private let authURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> QuotaSnapshot {
        var partial = PartialSnapshot()
        var originalError: Error?

        do {
            partial = try await self.fetchFromHTTP()
        } catch {
            originalError = error
        }

        if partial.fiveHour == nil || partial.weekly == nil,
           let local = await CodexAppServerRateLimits.fetch()
        {
            partial.mergeMissing(from: local)
        }

        guard partial.fiveHour != nil || partial.weekly != nil else {
            throw originalError ?? QuotaError.invalidResponse
        }

        return QuotaSnapshot(
            fiveHourRemainingPercent: partial.fiveHour?.remainingPercent,
            weeklyRemainingPercent: partial.weekly?.remainingPercent,
            fiveHourResetAt: partial.fiveHour?.resetAt,
            weeklyResetAt: partial.weekly?.resetAt,
            updatedAt: Date())
    }

    private func fetchFromHTTP() async throws -> PartialSnapshot {
        let authData: Data
        do {
            authData = try Data(contentsOf: self.authURL)
        } catch {
            throw QuotaError.authMissing
        }

        let auth: AuthFile
        do {
            auth = try JSONDecoder().decode(AuthFile.self, from: authData)
        } catch {
            throw QuotaError.authMissing
        }

        var request = URLRequest(url: self.usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenu/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode)
        }

        let usage: UsageResponse
        do {
            usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw QuotaError.invalidResponse
        }

        var result = PartialSnapshot()
        Self.add(usage.rateLimit.primaryWindow, legacyKind: .fiveHour, to: &result)
        Self.add(usage.rateLimit.secondaryWindow, legacyKind: .weekly, to: &result)
        return result
    }

    private static func add(_ window: UsageResponse.RateLimit.Window?, legacyKind: WindowKind, to result: inout PartialSnapshot) {
        guard let window else { return }
        let kind = window.durationSeconds.map(WindowKind.fromDuration(seconds:)) ?? legacyKind
        let value = QuotaWindow(
            remainingPercent: self.remaining(fromUsed: window.usedPercent),
            resetAt: window.resetAt.map(Date.init(timeIntervalSince1970:)))
        result.set(value, for: kind)
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func remaining(fromUsed usedPercent: Double) -> Double {
        self.clamp(100 - usedPercent)
    }
}

private enum WindowKind { case fiveHour, weekly
    static func fromDuration(seconds: TimeInterval) -> WindowKind {
        seconds < 24 * 60 * 60 ? .fiveHour : .weekly
    }
}

private struct QuotaWindow {
    let remainingPercent: Double
    let resetAt: Date?
}

private struct PartialSnapshot {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?

    mutating func set(_ value: QuotaWindow, for kind: WindowKind) {
        switch kind { case .fiveHour: self.fiveHour = value; case .weekly: self.weekly = value }
    }

    mutating func mergeMissing(from other: PartialSnapshot) {
        if self.fiveHour == nil { self.fiveHour = other.fiveHour }
        if self.weekly == nil { self.weekly = other.weekly }
    }
}

private enum CodexAppServerRateLimits {
    static func fetch() async -> PartialSnapshot? {
        await Task.detached(priority: .utility) { self.fetchSynchronously() }.value
    }

    private static func fetchSynchronously() -> PartialSnapshot? {
        guard let executable = self.executableURL() else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let messages = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-quota-menu","version":"1.1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
        ].joined(separator: "\n") + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))

        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if process.isRunning { process.terminate() }
        }

        var buffer = Data()
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let result = self.parseResponse(Data(line)) {
                    process.terminate()
                    return result
                }
            }
        }
        return nil
    }

    private static func parseResponse(_ data: Data) -> PartialSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["id"] as? NSNumber)?.intValue == 2,
              let result = root["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any]
        else { return nil }

        var snapshot = PartialSnapshot()
        self.add(limits["primary"] as? [String: Any], legacyKind: .fiveHour, to: &snapshot)
        self.add(limits["secondary"] as? [String: Any], legacyKind: .weekly, to: &snapshot)
        return snapshot
    }

    private static func add(_ window: [String: Any]?, legacyKind: WindowKind, to result: inout PartialSnapshot) {
        guard let window, let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return }
        let minutes = (window["windowDurationMins"] as? NSNumber)?.doubleValue
        let kind = minutes.map { WindowKind.fromDuration(seconds: $0 * 60) } ?? legacyKind
        let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        result.set(QuotaWindow(remainingPercent: min(100, max(0, 100 - used)), resetAt: reset), for: kind)
    }

    private static func executableURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}

private enum QuotaImageRenderer {
    private static let height: CGFloat = 22
    private static let blockX: CGFloat = 13
    private static let blockWidth: CGFloat = 5
    private static let blockGap: CGFloat = 1.5
    private static let percentGap: CGFloat = 3
    private static let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)

    static func render(
        fiveHourPercent: Double?,
        weeklyPercent: Double?,
        appearance: NSAppearance?) -> NSImage
    {
        if fiveHourPercent == nil, let weeklyPercent {
            return self.renderSingle(label: "7d", percent: weeklyPercent, appearance: appearance)
        }
        if weeklyPercent == nil, let fiveHourPercent {
            return self.renderSingle(label: "5h", percent: fiveHourPercent, appearance: appearance)
        }

        let image = NSImage(size: self.canvasSize(
            fiveHourPercent: fiveHourPercent,
            weeklyPercent: weeklyPercent))
        image.lockFocus()
        defer { image.unlockFocus() }

        let draw = {
            self.drawRow(label: "5h", percent: fiveHourPercent, y: 12)
            self.drawRow(label: "7d", percent: weeklyPercent, y: 1)
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        image.isTemplate = false
        return image
    }

    private static func renderSingle(label: String, percent: Double, appearance: NSAppearance?) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let labelWidth = (label as NSString).size(withAttributes: attributes).width
        let percentText = self.percentText(percent)
        let percentWidth = (percentText as NSString).size(withAttributes: attributes).width
        let blockWidth: CGFloat = 7
        let blockGap: CGFloat = 2
        let textGap: CGFloat = 4
        let blockX = ceil(labelWidth + textGap)
        let percentX = blockX + 5 * blockWidth + 4 * blockGap + textGap
        let image = NSImage(size: NSSize(width: ceil(percentX + percentWidth), height: self.height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let draw = {
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            (label as NSString).draw(at: NSPoint(x: 0, y: 4), withAttributes: textAttributes)
            let filledCount = min(5, max(0, Int(round(percent / 20))))
            let activeColor: NSColor = if percent >= 50 {
                .systemGreen
            } else if percent >= 20 {
                .systemOrange
            } else {
                .systemRed
            }
            for index in 0..<5 {
                let rect = NSRect(
                    x: blockX + CGFloat(index) * (blockWidth + blockGap),
                    y: 6,
                    width: blockWidth,
                    height: 10)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                if index < filledCount {
                    activeColor.setFill()
                } else {
                    NSColor.systemBlue.withAlphaComponent(0.22).setFill()
                }
                path.fill()
            }
            (percentText as NSString).draw(at: NSPoint(x: percentX, y: 4), withAttributes: textAttributes)
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        image.isTemplate = false
        return image
    }

    private static func drawRow(label: String, percent: Double?, y: CGFloat) {
        let textColor = NSColor.labelColor
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: self.font,
            .foregroundColor: textColor,
        ]

        (label as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: textAttributes)

        let blockHeight: CGFloat = 7
        let filledCount = percent.map { min(5, max(0, Int(round($0 / 20)))) } ?? 0
        let activeColor: NSColor = if let percent {
            if percent >= 50 {
                .systemGreen
            } else if percent >= 20 {
                .systemOrange
            } else {
                .systemRed
            }
        } else {
            .tertiaryLabelColor
        }

        for index in 0..<5 {
            let rect = NSRect(
                x: self.blockX + CGFloat(index) * (self.blockWidth + self.blockGap),
                y: y + 1,
                width: self.blockWidth,
                height: blockHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            if percent == nil {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            } else if index < filledCount {
                activeColor.setFill()
            } else {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            }
            path.fill()
        }

        let percentText = self.percentText(percent)
        (percentText as NSString).draw(
            at: NSPoint(x: self.percentX, y: y),
            withAttributes: textAttributes)
    }

    private static var percentX: CGFloat {
        self.blockX + CGFloat(5) * self.blockWidth + CGFloat(4) * self.blockGap + self.percentGap
    }

    private static func percentText(_ percent: Double?) -> String {
        percent.map { "\(Int(round($0)))%" } ?? "--%"
    }

    private static func canvasSize(fiveHourPercent: Double?, weeklyPercent: Double?) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: self.font]
        let fiveHourWidth = (self.percentText(fiveHourPercent) as NSString).size(withAttributes: attributes).width
        let weeklyWidth = (self.percentText(weeklyPercent) as NSString).size(withAttributes: attributes).width
        let width = ceil(self.percentX + max(fiveHourWidth, weeklyWidth))
        return NSSize(width: width, height: self.height)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let quotaService = QuotaService()
    private var statusItem: NSStatusItem?
    private var barPanel: NSPanel?
    private var barButton: NSButton?
    private var barScreen: NSScreen?
    private var processTimer: Timer?
    private var refreshTimer: Timer?
    private var visibilityTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: Error?
    private var codexWasRunning = false
    private var overlayMenuIsOpen = false

    private var usesOverlayStatusItem: Bool {
        ProcessInfo.processInfo.environment["CODEX_QUOTA_MENU_OVERLAY"] == "1"
            || UserDefaults.standard.bool(forKey: overlayModePreferenceKey)
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        self.checkCodexLifecycle()
        self.processTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCodexLifecycle() }
        }
    }

    func applicationWillTerminate(_: Notification) {
        self.processTimer?.invalidate()
        self.refreshTimer?.invalidate()
        self.visibilityTimer?.invalidate()
        self.refreshTask?.cancel()
    }

    private func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == codexBundleIdentifier && !$0.isTerminated
        }
    }

    private func checkCodexLifecycle() {
        let isRunning = self.isCodexRunning()
        guard isRunning != self.codexWasRunning else { return }
        self.codexWasRunning = isRunning

        if isRunning {
            self.showStatusItem()
            self.startRefreshing()
        } else {
            self.stopRefreshing()
            self.hideStatusItem()
        }
    }

    private func showStatusItem() {
        if !self.usesOverlayStatusItem {
            guard self.statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: 64)
            item.autosaveName = statusItemAutosaveName
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleNone
            item.button?.toolTip = "Codex 额度"
            item.menu = self.makeMenu()
            self.statusItem = item
            self.updateImage()
            return
        }

        guard self.barPanel == nil else { return }
        let size = NSSize(width: 64, height: 22)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let button = NSButton(frame: NSRect(origin: .zero, size: size))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(self.openOverlayMenu(_:))
        panel.contentView = button
        self.barPanel = panel
        self.barButton = button
        self.barScreen = NSScreen.main ?? NSScreen.screens.first
        self.positionMenuBarPanel()
        self.updatePanelVisibility()

        self.visibilityTimer?.invalidate()
        self.visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePanelVisibility() }
        }
        self.updateImage()
    }

    private func hideStatusItem() {
        if let item = self.statusItem {
            item.menu = nil
            NSStatusBar.system.removeStatusItem(item)
            self.statusItem = nil
        }
        self.visibilityTimer?.invalidate()
        self.visibilityTimer = nil
        self.barPanel?.orderOut(nil)
        self.barPanel = nil
        self.barButton = nil
        self.barScreen = nil
        self.overlayMenuIsOpen = false
    }

    private func positionMenuBarPanel() {
        guard let panel = self.barPanel,
              let screen = self.barScreen else { return }
        let configuredInset = UserDefaults.standard.object(forKey: overlayRightInsetPreferenceKey) as? Double
        let x: CGFloat
        if let configuredInset {
            let rightInset = max(0, CGFloat(configuredInset))
            x = screen.frame.maxX - rightInset - panel.frame.width
        } else if let statusItemsStart = self.controlCenterMenuBarFrames(on: screen).map(\.minX).min() {
            x = statusItemsStart - 8 - panel.frame.width
        } else {
            x = screen.frame.maxX - 586 - panel.frame.width
        }
        panel.setFrameOrigin(NSPoint(
            x: max(screen.frame.minX, x),
            y: screen.frame.maxY - 27))
    }

    private func updatePanelVisibility() {
        guard let panel = self.barPanel else { return }
        if self.overlayMenuIsOpen || self.isSystemMenuBarVisible() {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func isSystemMenuBarVisible() -> Bool {
        guard let screen = self.barScreen else { return false }
        let mouse = NSEvent.mouseLocation
        if screen.frame.contains(mouse), mouse.y >= screen.frame.maxY - 40 {
            return true
        }

        let primaryMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? screen.frame.maxY
        let expectedX = screen.frame.minX
        let expectedY = primaryMaxY - screen.frame.maxY
        if self.controlCenterMenuBarFrames(on: screen).contains(where: {
            abs($0.minY - expectedY) <= 2
        }) {
            return true
        }

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (25...30).contains(layer),
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0.5,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            let isFullWidthMenu = abs(x - expectedX) <= 2
                && width >= screen.frame.width - 2
            return abs(y - expectedY) <= 2
                && (20...40).contains(height)
                && isFullWidthMenu
        }
    }

    private func controlCenterMenuBarFrames(on screen: NSScreen) -> [CGRect] {
        guard let controlCenterPID = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter" && !$0.isTerminated
        })?.processIdentifier,
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let primaryMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? screen.frame.maxY
        let expectedY = primaryMaxY - screen.frame.maxY

        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 25,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == controlCenterPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  (20...40).contains(height),
                  abs(y - expectedY) <= 120,
                  x >= screen.frame.minX - 2,
                  x + width <= screen.frame.maxX + 2
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private func startRefreshing() {
        self.refreshNow()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func stopRefreshing() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
    }

    @objc private func refreshNow() {
        guard self.codexWasRunning else { return }
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.quotaService.fetch()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.lastSnapshot = snapshot
                    self.lastError = nil
                    self.updateImage()
                    self.statusItem?.menu = self.makeMenu()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.lastError = error
                    self.updateImage()
                    self.statusItem?.menu = self.makeMenu()
                }
            }
        }
    }

    private func updateImage() {
        guard self.statusItem != nil || self.barButton != nil else { return }
        let appearance = self.barButton == nil
            ? self.statusItem?.button?.effectiveAppearance
            : NSAppearance(named: .darkAqua)
        let image = QuotaImageRenderer.render(
            fiveHourPercent: self.lastSnapshot?.fiveHourRemainingPercent,
            weeklyPercent: self.lastSnapshot?.weeklyRemainingPercent,
            appearance: appearance)

        if let button = self.statusItem?.button {
            self.statusItem?.length = image.size.width
            button.image = image
            if let snapshot = self.lastSnapshot {
                let available = [
                    snapshot.fiveHourRemainingPercent.map { "5h \(Self.percentText($0))" },
                    snapshot.weeklyRemainingPercent.map { "7d \(Self.percentText($0))" },
                ].compactMap { $0 }.joined(separator: "，")
                button.toolTip = "Codex 剩余额度：\(available)"
            } else if let lastError {
                button.toolTip = "Codex 额度读取失败：\(lastError.localizedDescription)"
            } else {
                button.toolTip = "正在读取 Codex 额度…"
            }
        }

        if let button = self.barButton {
            button.image = image
            button.frame = NSRect(origin: .zero, size: image.size)
            self.barPanel?.setContentSize(image.size)
            self.positionMenuBarPanel()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Codex 实时额度", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if let snapshot = self.lastSnapshot {
            if let fiveHour = snapshot.fiveHourRemainingPercent {
                menu.addItem(self.infoItem(
                    title: "5 小时：剩余 \(Self.percentText(fiveHour))",
                    resetAt: snapshot.fiveHourResetAt))
            }
            if let weekly = snapshot.weeklyRemainingPercent {
                menu.addItem(self.infoItem(
                    title: "7 天：剩余 \(Self.percentText(weekly))",
                    resetAt: snapshot.weeklyResetAt))
            }
            let updated = NSMenuItem(
                title: "更新于 \(Self.timeFormatter.string(from: snapshot.updatedAt))",
                action: nil,
                keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
        } else if let lastError {
            let errorItem = NSMenuItem(
                title: "读取失败：\(lastError.localizedDescription)",
                action: nil,
                keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        } else {
            let loading = NSMenuItem(title: "正在读取…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(self.refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let openUsage = NSMenuItem(
            title: "打开 Codex 用量页面",
            action: #selector(self.openUsagePage),
            keyEquivalent: "")
        openUsage.target = self
        menu.addItem(openUsage)

        let binding = NSMenuItem(title: "已绑定 Codex 启动与退出", action: nil, keyEquivalent: "")
        binding.isEnabled = false
        menu.addItem(binding)
        return menu
    }

    @objc private func openOverlayMenu(_ sender: NSButton) {
        let menu = self.makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    func menuWillOpen(_: NSMenu) {
        self.overlayMenuIsOpen = true
    }

    func menuDidClose(_: NSMenu) {
        self.overlayMenuIsOpen = false
        self.updatePanelVisibility()
    }

    private func infoItem(title: String, resetAt: Date?) -> NSMenuItem {
        let suffix = resetAt.map { " · \(Self.resetFormatter.string(from: $0)) 重置" } ?? ""
        let item = NSMenuItem(title: title + suffix, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func percentText(_ percent: Double?) -> String {
        percent.map { "\(Int(round($0)))%" } ?? "--%"
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.indices.contains(previewIndex + 1)
{
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1])
    let image = QuotaImageRenderer.render(
        fiveHourPercent: 40,
        weeklyPercent: 90,
        appearance: NSAppearance(named: .darkAqua))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Failed to render preview\n", stderr)
        exit(1)
    }
    try png.write(to: outputURL)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
