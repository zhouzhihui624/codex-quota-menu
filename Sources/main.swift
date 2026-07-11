import AppKit
import Foundation

private let codexBundleIdentifier = "com.openai.codex"
private let statusItemAutosaveName = "codex-quota-menu"

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

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
            }
        }

        let primaryWindow: Window
        let secondaryWindow: Window

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
    let fiveHourRemainingPercent: Double
    let weeklyRemainingPercent: Double
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

        return QuotaSnapshot(
            fiveHourRemainingPercent: Self.remaining(fromUsed: usage.rateLimit.primaryWindow.usedPercent),
            weeklyRemainingPercent: Self.remaining(fromUsed: usage.rateLimit.secondaryWindow.usedPercent),
            fiveHourResetAt: usage.rateLimit.primaryWindow.resetAt.map(Date.init(timeIntervalSince1970:)),
            weeklyResetAt: usage.rateLimit.secondaryWindow.resetAt.map(Date.init(timeIntervalSince1970:)),
            updatedAt: Date())
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func remaining(fromUsed usedPercent: Double) -> Double {
        self.clamp(100 - usedPercent)
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quotaService = QuotaService()
    private var statusItem: NSStatusItem?
    private var processTimer: Timer?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: Error?
    private var codexWasRunning = false

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
        guard self.statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 64)
        item.autosaveName = statusItemAutosaveName
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.toolTip = "Codex 额度"
        item.menu = self.makeMenu()
        self.statusItem = item
        self.updateImage()
    }

    private func hideStatusItem() {
        guard let item = self.statusItem else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
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
        guard let button = self.statusItem?.button else { return }
        let image = QuotaImageRenderer.render(
            fiveHourPercent: self.lastSnapshot?.fiveHourRemainingPercent,
            weeklyPercent: self.lastSnapshot?.weeklyRemainingPercent,
            appearance: button.effectiveAppearance)
        self.statusItem?.length = image.size.width
        button.image = image

        if let snapshot = self.lastSnapshot {
            button.toolTip = "Codex 剩余额度：5h \(Int(round(snapshot.fiveHourRemainingPercent)))%，7d \(Int(round(snapshot.weeklyRemainingPercent)))%"
        } else if let lastError {
            button.toolTip = "Codex 额度读取失败：\(lastError.localizedDescription)"
        } else {
            button.toolTip = "正在读取 Codex 额度…"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Codex 实时额度", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if let snapshot = self.lastSnapshot {
            menu.addItem(self.infoItem(
                title: "5 小时：剩余 \(Int(round(snapshot.fiveHourRemainingPercent)))%",
                resetAt: snapshot.fiveHourResetAt))
            menu.addItem(self.infoItem(
                title: "7 天：剩余 \(Int(round(snapshot.weeklyRemainingPercent)))%",
                resetAt: snapshot.weeklyResetAt))
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

    private func infoItem(title: String, resetAt: Date?) -> NSMenuItem {
        let suffix = resetAt.map { " · \(Self.resetFormatter.string(from: $0)) 重置" } ?? ""
        let item = NSMenuItem(title: title + suffix, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
