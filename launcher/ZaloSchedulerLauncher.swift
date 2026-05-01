import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if !AUTOMATION_ONLY

@main
struct ZaloSchedulerLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1080, minHeight: 760)
        }
        .windowResizability(.contentSize)
    }
}

extension LauncherModel {
    var bundleExecutablePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ZaloSchedulerLauncher").path
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        _ = _forceAutomationBootstrap
        super.init()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private func launchAutomationModeIfNeeded() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty, isAutomationCommand(args[0]) else {
        return
    }

    do {
        _ = try runAutomationCommand(arguments: args)
        exit(0)
    } catch {
        let message = automationErrorMessage(from: error)
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        exit(1)
    }
}

private let _automationBootstrap: Void = {
    launchAutomationModeIfNeeded()
}()

private let _forceAutomationBootstrap = _automationBootstrap

#endif

@MainActor
final class LauncherModel: ObservableObject {
    @Published var configPath: String
    @Published var recipient: String = ""
    @Published var message: String = ""
    @Published var imagePathsText: String = ""
    @Published var logText: String = ""
    @Published var schedulerRunning: Bool = false
    @Published var statusSummary: String = "Chưa kiểm tra."
    @Published var pythonPath: String = "Đang dò..."
    @Published var accessibilityTrusted: Bool?
    @Published var accessibilitySummary: String = "Chưa kiểm tra quyền Accessibility."
    @Published var accessibilityProcessName: String = "ZaloSchedulerLauncher"
    @Published var accessibilityExecutablePath: String = ""
    @Published var currentTask: String?

    private var schedulerProcess: Process?
    private let fileManager = FileManager.default

    let resourceRoot: URL
    let dataRoot: URL
    let defaultConfigPath: URL
    let statePath: URL

    init() {
        self.resourceRoot = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.dataRoot = appSupportBase.appendingPathComponent("ZaloSchedulerLauncher", isDirectory: true)
        self.defaultConfigPath = dataRoot.appendingPathComponent("config/jobs.example.json")
        self.statePath = dataRoot.appendingPathComponent("config/state.json")
        self.configPath = defaultConfigPath.path

        bootstrapDataDirectory()
        self.pythonPath = Self.resolvePythonPath() ?? "Không tìm thấy python3"
        appendLog("Resource root: \(resourceRoot.path)")
        appendLog("Data root: \(dataRoot.path)")
        appendLog("Config mặc định: \(configPath)")
        appendLog("Python: \(pythonPath)")
        checkAccessibilityStatus()
    }

    deinit {
        schedulerProcess?.terminate()
    }

    func buildHelper() {
        runOneShot(label: "Build helper", arguments: ["build-helper"])
    }

    func checkAccessibilityStatus() {
        runOneShot(label: "Kiểm tra Accessibility", arguments: ["accessibility-status"]) { [weak self] stdout in
            self?.updateAccessibilityStatus(from: stdout)
        }
    }

    func requestAccessibility() {
        runOneShot(label: "Yêu cầu Accessibility", arguments: ["request-accessibility"]) { [weak self] stdout in
            self?.updateAccessibilityStatus(from: stdout)
        }
    }

    func probeZalo() {
        runOneShot(label: "Probe Zalo", arguments: ["probe"]) { [weak self] stdout in
            self?.updateProbeStatus(from: stdout)
        }
    }

    func validateConfig() {
        runOneShot(label: "Validate config", arguments: ["validate-config", "--config", configPath])
    }

    func openChat() {
        guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("Thiếu recipient để mở chat test.")
            return
        }
        runOneShot(label: "Open chat", arguments: ["open-chat", "--recipient", recipient])
    }

    func sendTestNow() {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            appendLog("Thiếu recipient để gửi thử.")
            return
        }

        var arguments = ["send-now", "--recipient", trimmedRecipient]
        if !message.isEmpty {
            arguments.append(contentsOf: ["--message", message])
        }
        for image in imagePaths() {
            arguments.append(contentsOf: ["--image", image])
        }
        runOneShot(label: "Send test", arguments: arguments)
    }

    func startScheduler() {
        guard schedulerProcess == nil else {
            appendLog("Scheduler đang chạy.")
            return
        }

        guard let python = Self.resolvePythonPath() else {
            appendLog("Không tìm thấy python3 để start scheduler.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            resourceRoot.appendingPathComponent("main.py").path,
            "run",
            "--config", configPath,
            "--state", statePath.path,
        ]
        process.environment = commandEnvironment()
        process.currentDirectoryURL = dataRoot

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.appendLog(text.trimmingCharacters(in: .newlines))
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                self?.schedulerProcess = nil
                self?.schedulerRunning = false
                self?.appendLog("Scheduler dừng với mã \(proc.terminationStatus).")
            }
        }

        do {
            try process.run()
            schedulerProcess = process
            schedulerRunning = true
            appendLog("Scheduler đã start với config: \(configPath)")
        } catch {
            appendLog("Không thể start scheduler: \(error.localizedDescription)")
        }
    }

    func stopScheduler() {
        guard let process = schedulerProcess else {
            appendLog("Scheduler chưa chạy.")
            return
        }
        process.terminate()
        appendLog("Đã gửi tín hiệu dừng scheduler.")
    }

    func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: (configPath as NSString).deletingLastPathComponent)

        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            appendLog("Đã chọn config: \(configPath)")
        }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK {
            let selected = panel.urls.map(\.path)
            if !selected.isEmpty {
                let existing = imagePaths()
                imagePathsText = (existing + selected).joined(separator: "\n")
                appendLog("Đã thêm \(selected.count) ảnh test.")
            }
        }
    }

    func openConfigInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    func openDataFolder() {
        NSWorkspace.shared.open(dataRoot)
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(dataRoot.appendingPathComponent("logs", isDirectory: true))
    }

    func clearLogs() {
        logText = ""
    }

    func copyLogs() {
        guard !logText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
        appendLog("Đã copy log vào clipboard.")
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            appendLog("Không mở được trang Accessibility.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func imagePaths() -> [String] {
        imagePathsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func updateProbeStatus(from stdout: String) {
        guard let data = stdout.data(using: .utf8) else {
            statusSummary = "Probe xong nhưng không đọc được dữ liệu."
            return
        }

        struct Probe: Decodable {
            struct Element: Decodable {
                let role: String
                let value: String
            }

            let appRunning: Bool
            let focusedWindowTitle: String
            let searchField: Element?
            let messageInput: Element?
            let imageButton: Element?
        }

        do {
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            statusSummary = """
            appRunning=\(probe.appRunning)
            window=\(probe.focusedWindowTitle)
            search=\(probe.searchField?.role ?? "-")
            input=\(probe.messageInput?.value ?? "-")
            image=\(probe.imageButton?.value ?? "-")
            """
        } catch {
            statusSummary = "Probe có output nhưng parse JSON lỗi."
        }
    }

    private func updateAccessibilityStatus(from stdout: String) {
        guard let data = stdout.data(using: .utf8) else {
            accessibilityTrusted = nil
            accessibilitySummary = "Không đọc được trạng thái Accessibility."
            return
        }

        struct TrustReport: Decodable {
            let trusted: Bool
            let processName: String
            let executablePath: String
            let bundleIdentifier: String?
            let message: String
        }

        do {
            let report = try JSONDecoder().decode(TrustReport.self, from: data)
            accessibilityTrusted = report.trusted
            accessibilitySummary = report.message
            accessibilityProcessName = report.processName
            accessibilityExecutablePath = report.executablePath
        } catch {
            accessibilityTrusted = nil
            accessibilitySummary = "Có output nhưng parse trạng thái Accessibility lỗi."
        }
    }

    private func runOneShot(label: String, arguments: [String], onSuccess: ((String) -> Void)? = nil) {
        if let currentTask {
            appendLog("Đang chạy '\(currentTask)'. Đợi lệnh hiện tại xong rồi thử lại.")
            return
        }

        guard let python = Self.resolvePythonPath() else {
            appendLog("Không tìm thấy python3 để chạy: \(label)")
            return
        }

        currentTask = label
        appendLog(">> \(label): \(arguments.joined(separator: " "))")
        let resourceRoot = resourceRoot
        let dataRoot = dataRoot
        let environment = commandEnvironment()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [resourceRoot.appendingPathComponent("main.py").path] + arguments
            process.environment = environment
            process.currentDirectoryURL = dataRoot

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        self?.appendLog(cleaned)
                    }
                    if process.terminationStatus == 0 {
                        onSuccess?(text)
                    } else {
                        self?.appendLog("Lệnh '\(label)' lỗi với mã \(process.terminationStatus).")
                    }
                    self?.currentTask = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("Không chạy được '\(label)': \(error.localizedDescription)")
                    self?.currentTask = nil
                }
            }
        }
    }

    private func bootstrapDataDirectory() {
        do {
            try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let configDir = dataRoot.appendingPathComponent("config", isDirectory: true)
            let buildDir = dataRoot.appendingPathComponent("build", isDirectory: true)
            let logsDir = dataRoot.appendingPathComponent("logs", isDirectory: true)
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: buildDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

            let bundledConfig = resourceRoot.appendingPathComponent("config/jobs.example.json")
            if fileManager.fileExists(atPath: bundledConfig.path), !fileManager.fileExists(atPath: defaultConfigPath.path) {
                try fileManager.copyItem(at: bundledConfig, to: defaultConfigPath)
            }

            if !fileManager.fileExists(atPath: statePath.path) {
                let initial = Data("{\n  \"jobs\": {}\n}\n".utf8)
                try initial.write(to: statePath)
            }
        } catch {
            appendLog("Không bootstrap được data dir: \(error.localizedDescription)")
        }
    }

    private func commandEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ZALO_SCHEDULER_RESOURCE_ROOT"] = resourceRoot.path
        env["ZALO_SCHEDULER_DATA_ROOT"] = dataRoot.path
        return env
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        if logText.isEmpty {
            logText = text
        } else {
            logText += "\n" + text
        }
    }

    static func resolvePythonPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var model = LauncherModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        schedulerCard
                        accessibilityCard
                        configCard
                        probeCard
                    }
                    .frame(width: 380)

                    VStack(alignment: .leading, spacing: 14) {
                        testCard
                        logCard
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Zalo Scheduler")
                    .font(.system(size: 28, weight: .semibold))
                Text("Điều khiển lịch gửi, kiểm tra Zalo và gửi thử từ một màn hình.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let currentTask = model.currentTask {
                ProgressView()
                    .controlSize(.small)
                Text(currentTask)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            statusPill(
                model.schedulerRunning ? "Đang chạy" : "Đang dừng",
                systemImage: model.schedulerRunning ? "play.fill" : "pause.fill",
                color: model.schedulerRunning ? .green : .orange
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var schedulerCard: some View {
        panel("Scheduler", systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    metricTile(
                        title: "Lịch gửi",
                        value: model.schedulerRunning ? "Đang chạy" : "Đang dừng",
                        systemImage: model.schedulerRunning ? "checkmark.circle.fill" : "pause.circle.fill",
                        color: model.schedulerRunning ? .green : .orange
                    )
                    metricTile(
                        title: "Python",
                        value: pythonDisplayName,
                        systemImage: "terminal.fill",
                        color: .blue
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        model.startScheduler()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.schedulerRunning)

                    Button {
                        model.stopScheduler()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!model.schedulerRunning)

                    Spacer()

                    Button {
                        model.validateConfig()
                    } label: {
                        Label("Kiểm tra", systemImage: "checklist")
                    }
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var accessibilityCard: some View {
        panel("Accessibility", systemImage: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: accessibilityIcon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(accessibilityColor)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(accessibilityTitle)
                            .font(.headline)
                        Text(model.accessibilitySummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                pathBlock(title: "App/process cần quyền", value: model.accessibilityExecutablePath.isEmpty ? model.accessibilityProcessName : model.accessibilityExecutablePath)

                HStack(spacing: 10) {
                    Button {
                        model.checkAccessibilityStatus()
                    } label: {
                        Label("Kiểm tra", systemImage: "arrow.clockwise")
                    }

                    Button {
                        model.requestAccessibility()
                    } label: {
                        Label("Yêu cầu quyền", systemImage: "person.crop.circle.badge.checkmark")
                    }

                    Button {
                        model.openAccessibilitySettings()
                    } label: {
                        Label("Cài đặt", systemImage: "gearshape")
                    }
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var configCard: some View {
        panel("Config & dữ liệu", systemImage: "folder.fill") {
            VStack(alignment: .leading, spacing: 12) {
                pathBlock(title: "Config", value: model.configPath)
                pathBlock(title: "Data", value: model.dataRoot.path)

                HStack(spacing: 10) {
                    Button {
                        model.chooseConfigFile()
                    } label: {
                        Label("Chọn", systemImage: "doc.badge.plus")
                    }

                    Button {
                        model.openConfigInFinder()
                    } label: {
                        Label("Mở", systemImage: "doc.text.magnifyingglass")
                    }

                    Menu {
                        Button("Data folder", systemImage: "folder") { model.openDataFolder() }
                        Button("Logs", systemImage: "text.alignleft") { model.openLogsFolder() }
                    } label: {
                        Label("Thư mục", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var probeCard: some View {
        panel("Probe Zalo", systemImage: "scope") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.statusSummary)
                    .textSelection(.enabled)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        model.probeZalo()
                    } label: {
                        Label("Probe", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.buildHelper()
                    } label: {
                        Label("Build helper", systemImage: "hammer")
                    }
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var testCard: some View {
        panel("Gửi thử", systemImage: "paperplane.fill") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Người nhận")
                        .font(.subheadline.weight(.medium))
                    TextField("Tên hoặc số điện thoại trong Zalo", text: $model.recipient)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tin nhắn")
                        .font(.subheadline.weight(.medium))
                    editor(text: $model.message, minHeight: 118)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ảnh đính kèm")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("Mỗi dòng một đường dẫn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    editor(text: $model.imagePathsText, minHeight: 92)

                    HStack(spacing: 10) {
                        Button {
                            model.chooseImages()
                        } label: {
                            Label("Chọn ảnh", systemImage: "photo.on.rectangle")
                        }

                        Button {
                            model.imagePathsText = ""
                        } label: {
                            Label("Xóa ảnh", systemImage: "trash")
                        }
                        .disabled(model.imagePathsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        model.openChat()
                    } label: {
                        Label("Mở chat", systemImage: "message")
                    }

                    Button {
                        model.sendTestNow()
                    } label: {
                        Label("Gửi ngay", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Label("Gửi ngay sẽ gửi thật vào Zalo", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var logCard: some View {
        panel("Console", systemImage: "terminal.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        model.copyLogs()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(model.logText.isEmpty)

                    Button {
                        model.clearLogs()
                    } label: {
                        Label("Xóa", systemImage: "trash")
                    }
                    .disabled(model.logText.isEmpty)

                    Spacer()
                }

                ScrollView {
                    Text(model.logText.isEmpty ? "Chưa có log." : model.logText)
                        .textSelection(.enabled)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(minHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var pythonDisplayName: String {
        URL(fileURLWithPath: model.pythonPath).lastPathComponent.isEmpty ? model.pythonPath : URL(fileURLWithPath: model.pythonPath).lastPathComponent
    }

    private var accessibilityTitle: String {
        switch model.accessibilityTrusted {
        case .some(true):
            return "Đã sẵn sàng"
        case .some(false):
            return "Cần cấp quyền"
        case .none:
            return "Chưa kiểm tra"
        }
    }

    private var accessibilityIcon: String {
        switch model.accessibilityTrusted {
        case .some(true):
            return "checkmark.shield.fill"
        case .some(false):
            return "exclamationmark.shield.fill"
        case .none:
            return "questionmark.circle.fill"
        }
    }

    private var accessibilityColor: Color {
        switch model.accessibilityTrusted {
        case .some(true):
            return .green
        case .some(false):
            return .orange
        case .none:
            return .secondary
        }
    }

    private func panel<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func statusPill(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func metricTile(title: String, value: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pathBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .textSelection(.enabled)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
    }
}
