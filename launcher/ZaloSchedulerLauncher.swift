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

private let _forceAutomationBootstrap: Void = _automationBootstrap

#endif

enum ScheduleType: String, CaseIterable, Identifiable {
    case daily
    case once

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:
            return "Lặp lại hằng ngày"
        case .once:
            return "Gửi một lần"
        }
    }

    var systemImage: String {
        switch self {
        case .daily:
            return "repeat"
        case .once:
            return "calendar"
        }
    }
}

enum MediaKind {
    case image
    case video

    var title: String {
        switch self {
        case .image:
            return "ảnh"
        case .video:
            return "video"
        }
    }

    var systemImage: String {
        switch self {
        case .image:
            return "photo"
        case .video:
            return "video"
        }
    }
}

struct SchedulerConfig: Codable {
    var jobs: [ScheduleJob]
}

struct ScheduleJob: Identifiable, Codable, Equatable {
    var id: String
    var recipient: String
    var message: String
    var images: [String]
    var schedule: JobSchedule

    static func fresh() -> ScheduleJob {
        ScheduleJob(
            id: "job-\(Int(Date().timeIntervalSince1970))",
            recipient: "",
            message: "",
            images: [],
            schedule: JobSchedule(type: ScheduleType.daily.rawValue, at: "08:30", days: [0, 1, 2, 3, 4, 5, 6])
        )
    }
}

struct JobSchedule: Codable, Equatable {
    var type: String
    var at: String
    var days: [Int]?
}

struct ValidationMessage: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

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
    @Published var jobs: [ScheduleJob] = []
    @Published var selectedJobID: String?
    @Published var configSummary: String = "Đang đọc lịch gửi."

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
        loadConfigFromDisk()
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
        guard saveConfigFromForm() else {
            return
        }
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
        guard saveConfigFromForm() else {
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

    func loadConfigFromDisk() {
        do {
            let url = URL(fileURLWithPath: configPath)
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(SchedulerConfig.self, from: data)
            jobs = config.jobs.isEmpty ? [ScheduleJob.fresh()] : config.jobs
            selectedJobID = jobs.first?.id
            configSummary = "Đã đọc \(jobs.count) lịch gửi."
        } catch {
            let fallback = ScheduleJob.fresh()
            jobs = [fallback]
            selectedJobID = fallback.id
            configSummary = "Không đọc được config. Đã tạo lịch trống để sửa lại."
            appendLog("Không đọc được config: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveConfigFromForm() -> Bool {
        do {
            let cleanedJobs = try normalizedJobsForSaving()
            let config = SchedulerConfig(jobs: cleanedJobs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            let url = URL(fileURLWithPath: configPath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            jobs = cleanedJobs
            if selectedJobID == nil {
                selectedJobID = cleanedJobs.first?.id
            }
            configSummary = "Đã lưu \(cleanedJobs.count) lịch gửi."
            appendLog("Đã lưu config: \(configPath)")
            return true
        } catch {
            configSummary = error.localizedDescription
            appendLog("Không lưu được config: \(error.localizedDescription)")
            return false
        }
    }

    func addJob() {
        var job = ScheduleJob.fresh()
        var suffix = 1
        while jobs.contains(where: { $0.id == job.id }) {
            suffix += 1
            job.id = "job-\(Int(Date().timeIntervalSince1970))-\(suffix)"
        }
        jobs.append(job)
        selectedJobID = job.id
        configSummary = "Đã thêm lịch mới."
    }

    func duplicateSelectedJob() {
        guard let index = jobs.firstIndex(where: { $0.id == selectedJobID }) else {
            return
        }

        var copy = jobs[index]
        copy.id = "job-\(Int(Date().timeIntervalSince1970))"
        copy.recipient = copy.recipient.isEmpty ? "" : "\(copy.recipient) copy"
        jobs.append(copy)
        selectedJobID = copy.id
        configSummary = "Đã nhân bản lịch gửi."
    }

    func deleteSelectedJob() {
        guard let id = selectedJobID, let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs.remove(at: index)
        if jobs.isEmpty {
            let fallback = ScheduleJob.fresh()
            jobs = [fallback]
            selectedJobID = fallback.id
        } else {
            selectedJobID = jobs[min(index, jobs.count - 1)].id
        }
        configSummary = "Đã xóa lịch gửi."
    }

    func chooseImages(for jobID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.mediaContentTypes

        if panel.runModal() == .OK, let index = jobs.firstIndex(where: { $0.id == jobID }) {
            let selected = panel.urls.map(\.path)
            jobs[index].images.append(contentsOf: selected)
            configSummary = "Đã thêm \(selected.count) tệp ảnh/video vào lịch gửi."
        }
    }

    func removeImage(_ imagePath: String, from jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        jobs[index].images.removeAll { $0 == imagePath }
        configSummary = "Đã xóa tệp khỏi lịch gửi."
    }

    private func normalizedJobsForSaving() throws -> [ScheduleJob] {
        var seenIDs: Set<String> = []
        return try jobs.enumerated().map { offset, rawJob in
            var job = rawJob
            job.id = job.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if job.id.isEmpty {
                job.id = "job-\(offset + 1)"
            }
            if seenIDs.contains(job.id) {
                job.id = "\(job.id)-\(offset + 1)"
            }
            seenIDs.insert(job.id)

            job.recipient = job.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            job.message = job.message.trimmingCharacters(in: .whitespacesAndNewlines)
            job.images = job.images
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !job.recipient.isEmpty else {
                throw ValidationMessage("Lịch \(offset + 1): thiếu người nhận.")
            }
            guard !job.message.isEmpty || !job.images.isEmpty else {
                throw ValidationMessage("Lịch \(offset + 1): cần tin nhắn hoặc ảnh/video.")
            }

            let type = ScheduleType(rawValue: job.schedule.type) ?? .daily
            job.schedule.type = type.rawValue
            switch type {
            case .daily:
                if Self.dailyDate(from: job.schedule.at) == nil {
                    job.schedule.at = "08:30"
                }
                let days = (job.schedule.days ?? [0, 1, 2, 3, 4, 5, 6]).filter { (0...6).contains($0) }
                job.schedule.days = days.isEmpty ? [0, 1, 2, 3, 4, 5, 6] : Array(Set(days)).sorted()
            case .once:
                if Self.onceDate(from: job.schedule.at) == nil {
                    job.schedule.at = Self.formatOnceDate(Date().addingTimeInterval(3600))
                }
                job.schedule.days = nil
            }

            return job
        }
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
            loadConfigFromDisk()
        }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.mediaContentTypes

        if panel.runModal() == .OK {
            let selected = panel.urls.map(\.path)
            if !selected.isEmpty {
                let existing = imagePaths()
                imagePathsText = (existing + selected).joined(separator: "\n")
                appendLog("Đã thêm \(selected.count) tệp ảnh/video test.")
            }
        }
    }

    var testImagePaths: [String] {
        imagePaths()
    }

    func removeTestImage(_ imagePath: String) {
        let remaining = imagePaths().filter { $0 != imagePath }
        imagePathsText = remaining.joined(separator: "\n")
    }

    func clearTestImages() {
        imagePathsText = ""
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
            let attachmentButton: Element?
        }

        do {
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            statusSummary = """
            appRunning=\(probe.appRunning)
            window=\(probe.focusedWindowTitle)
            search=\(probe.searchField?.role ?? "-")
            input=\(probe.messageInput?.value ?? "-")
            image=\(probe.imageButton?.value ?? "-")
            file=\(probe.attachmentButton?.value ?? "-")
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

        currentTask = label
        appendLog(">> \(label): \(arguments.joined(separator: " "))")
        let resourceRoot = resourceRoot
        let dataRoot = dataRoot
        let environment = commandEnvironment()
        let directArguments = directAutomationArguments(for: arguments)
        let fallbackPython: String?
        if directArguments == nil {
            guard let python = Self.resolvePythonPath() else {
                appendLog("Không tìm thấy python3 để chạy: \(label)")
                currentTask = nil
                return
            }
            fallbackPython = python
        } else {
            fallbackPython = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let directArguments {
                do {
                    let text = try Self.directAutomationOutput(arguments: directArguments)
                    DispatchQueue.main.async {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            self?.appendLog(cleaned)
                        }
                        onSuccess?(text)
                        self?.currentTask = nil
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.appendLog("ERROR: \(automationErrorMessage(from: error))")
                        self?.appendLog("Lệnh '\(label)' lỗi.")
                        self?.currentTask = nil
                    }
                }
                return
            }

            let process = Process()
            let python = fallbackPython ?? "python3"
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

    nonisolated private static func directAutomationOutput(arguments: [String]) throws -> String {
        guard let command = arguments.first else {
            throw ValidationMessage(automationUsage)
        }

        let automation = ZaloAutomation()
        switch command {
        case "accessibility-status":
            return try encodedJSON(automation.accessibilityStatus(prompt: false))
        case "request-accessibility":
            return try encodedJSON(automation.accessibilityStatus(prompt: true))
        case "probe":
            return try encodedJSON(automation.probe())
        case "open-chat":
            let request = try parseSendRequest(arguments: Array(arguments.dropFirst()))
            try automation.openChat(recipient: request.recipient)
            return ""
        case "send":
            let request = try parseSendRequest(arguments: Array(arguments.dropFirst()))
            try automation.send(request)
            return ""
        default:
            throw ValidationMessage(automationUsage)
        }
    }

    nonisolated private static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func directAutomationArguments(for arguments: [String]) -> [String]? {
        guard let command = arguments.first else {
            return nil
        }

        switch command {
        case "accessibility-status", "request-accessibility", "probe", "open-chat":
            return arguments
        case "send-now":
            return ["send"] + arguments.dropFirst()
        default:
            return nil
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

    static func onceDate(from value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return localDateFormatter.date(from: value)
    }

    static func formatOnceDate(_ date: Date) -> String {
        localDateFormatter.string(from: date)
    }

    static func dailyDate(from value: String) -> Date? {
        let parts = value.split(separator: ":")
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            return nil
        }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)
    }

    static func formatDailyTime(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 8, components.minute ?? 30)
    }

    private static var localDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }

    static var mediaContentTypes: [UTType] {
        [.image, .movie]
    }

    static func mediaKind(for path: String) -> MediaKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpeg", "mpg"]
        return videoExtensions.contains(ext) ? .video : .image
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
    private let brandPrimary = Color(red: 0.00, green: 0.62, blue: 0.55)
    private let brandPrimarySoft = Color(red: 0.00, green: 0.62, blue: 0.55).opacity(0.14)
    private let brandAccent = Color(red: 0.94, green: 0.40, blue: 0.30)
    private let successGreen = Color(red: 0.12, green: 0.68, blue: 0.36)
    private let warningOrange = Color(red: 0.91, green: 0.56, blue: 0.18)
    private let panelRadius: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        schedulerCard
                        accessibilityCard
                        advancedCard
                    }
                    .frame(width: 360)

                    VStack(alignment: .leading, spacing: 14) {
                        scheduleConfigCard
                        testCard
                        logCard
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
        }
        .background(appBackground)
        .tint(brandPrimary)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(brandPrimary)
                    .frame(width: 48, height: 48)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Zalo Scheduler")
                        .font(.system(size: 27, weight: .semibold))
                    statusPill(appVersionText, systemImage: "tag.fill", color: brandPrimary)
                }
                Text("Thiết lập lịch gửi rõ ràng, kiểm tra nhanh, vận hành ít thao tác.")
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
                color: model.schedulerRunning ? successGreen : warningOrange
            )

            statusPill(
                accessibilityTitle,
                systemImage: accessibilityIcon,
                color: accessibilityColor
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(headerBackground)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Phiên bản \(version) (\(build))"
    }

    private var appBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var panelBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var fieldBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    private var headerBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var schedulerCard: some View {
        panel("Điều khiển", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                statusBanner(
                    title: model.schedulerRunning ? "Lịch tự động đang chạy" : "Lịch tự động đang dừng",
                    detail: "\(model.jobs.count) lịch trong cấu hình hiện tại",
                    systemImage: model.schedulerRunning ? "checkmark.circle.fill" : "pause.circle.fill",
                    color: model.schedulerRunning ? successGreen : warningOrange
                )

                Button {
                    model.startScheduler()
                } label: {
                    Label("Bắt đầu chạy lịch", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.schedulerRunning || model.currentTask != nil)

                HStack(spacing: 10) {
                    Button {
                        model.stopScheduler()
                    } label: {
                        Label("Dừng", systemImage: "stop.fill")
                    }
                    .disabled(!model.schedulerRunning)

                    Spacer()

                    Button {
                        model.validateConfig()
                    } label: {
                        Label("Kiểm tra lịch", systemImage: "checklist")
                    }
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var accessibilityCard: some View {
        panel("Quyền điều khiển", systemImage: "hand.raised.fill") {
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

    private var advancedCard: some View {
        panel("Công cụ", systemImage: "wrench.and.screwdriver.fill") {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        pathBlock(title: "Config", value: model.configPath)
                        pathBlock(title: "Data", value: model.dataRoot.path)

                        HStack(spacing: 10) {
                            Button {
                                model.chooseConfigFile()
                            } label: {
                                Label("Chọn file", systemImage: "doc.badge.plus")
                            }

                            Button {
                                model.openConfigInFinder()
                            } label: {
                                Label("Mở file", systemImage: "doc.text.magnifyingglass")
                            }

                            Menu {
                                Button("Data folder", systemImage: "folder") { model.openDataFolder() }
                                Button("Logs", systemImage: "text.alignleft") { model.openLogsFolder() }
                            } label: {
                                Label("Thư mục", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("File & thư mục")
                        .font(.subheadline.weight(.medium))
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.statusSummary)
                            .textSelection(.enabled)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                            .padding(10)
                            .background(fieldBackground)
                            .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                            .overlay(panelStroke)

                        HStack(spacing: 10) {
                            Button {
                                model.probeZalo()
                            } label: {
                                Label("Probe", systemImage: "waveform.path.ecg")
                            }

                            Button {
                                model.buildHelper()
                            } label: {
                                Label("Build helper", systemImage: "hammer")
                            }
                        }
                        .disabled(model.currentTask != nil)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Kiểm tra Zalo")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var scheduleConfigCard: some View {
        panel("Cấu hình lịch gửi", systemImage: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 16) {
                scheduleToolbar

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Danh sách lịch")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(model.jobs.count)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(brandPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(brandPrimarySoft)
                                .clipShape(Capsule())
                        }

                        VStack(spacing: 8) {
                            ForEach(model.jobs) { job in
                                jobRow(job)
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 280)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                    .overlay(panelStroke)

                    if let index = model.jobs.firstIndex(where: { $0.id == model.selectedJobID }) {
                        jobEditor(job: $model.jobs[index])
                    } else {
                        emptyState("Chưa chọn lịch gửi", systemImage: "calendar.badge.exclamationmark")
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
            }
        }
    }

    private var scheduleToolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.addJob()
            } label: {
                Label("Thêm lịch", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Button {
                model.duplicateSelectedJob()
            } label: {
                Label("Nhân bản", systemImage: "plus.square.on.square")
            }
            .disabled(model.selectedJobID == nil)

            Button {
                model.deleteSelectedJob()
            } label: {
                Label("Xóa", systemImage: "trash")
            }
            .disabled(model.jobs.count <= 1)

            Spacer()

            Label(model.configSummary, systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                model.loadConfigFromDisk()
            } label: {
                Label("Tải lại", systemImage: "arrow.clockwise")
            }

            Button {
                model.saveConfigFromForm()
            } label: {
                Label("Lưu lịch", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .disabled(model.currentTask != nil)
    }

    private func jobRow(_ job: ScheduleJob) -> some View {
        let isSelected = job.id == model.selectedJobID
        let type = ScheduleType(rawValue: job.schedule.type) ?? .daily
        return Button {
            model.selectedJobID = job.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: type.systemImage)
                        .foregroundStyle(isSelected ? .white : brandPrimary)
                        .frame(width: 18)
                    Text(job.recipient.isEmpty ? "Chưa có người nhận" : job.recipient)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }

                Text(scheduleSummary(for: job))
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(job.message.isEmpty ? "Không có tin nhắn" : "Có tin nhắn", systemImage: job.message.isEmpty ? "text.badge.xmark" : "text.bubble")
                    Label("\(job.images.count) tệp", systemImage: "photo.on.rectangle")
                }
                .font(.caption2)
                .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? brandPrimary : panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func jobEditor(job: Binding<ScheduleJob>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedJobHeader(job.wrappedValue)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                field("Người nhận") {
                    TextField("Tên đúng như Zalo", text: job.recipient)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kiểu lịch")
                        .font(.subheadline.weight(.medium))
                    Picker("Kiểu lịch", selection: scheduleTypeBinding(for: job)) {
                        ForEach(ScheduleType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .frame(width: 250)
            }

            sectionBox("Nội dung gửi", systemImage: "text.bubble") {
                field("Tin nhắn") {
                    plainEditor(text: job.message, minHeight: 110)
                }
            }

            sectionBox("Thời gian gửi", systemImage: "clock") {
                scheduleEditor(job: job)
            }

            sectionBox("Ảnh/video đính kèm", systemImage: "photo.on.rectangle") {
                mediaAttachmentEditor(job: job)
            }

            HStack {
                Spacer()
                Button {
                    model.saveConfigFromForm()
                } label: {
                    Label("Lưu lịch gửi", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.currentTask != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
    }

    private func selectedJobHeader(_ job: ScheduleJob) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(brandPrimarySoft)
                    .frame(width: 42, height: 42)
                Image(systemName: (ScheduleType(rawValue: job.schedule.type) ?? .daily).systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brandPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(job.recipient.isEmpty ? "Lịch gửi chưa đặt tên" : job.recipient)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(scheduleSummary(for: job))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusPill(job.message.isEmpty ? "Chưa có tin nhắn" : "Có tin nhắn", systemImage: "text.bubble", color: job.message.isEmpty ? warningOrange : brandPrimary)
            statusPill("\(job.images.count) tệp", systemImage: "paperclip", color: brandAccent)
        }
        .padding(.bottom, 2)
    }

    private func mediaAttachmentEditor(job: Binding<ScheduleJob>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button {
                        model.chooseImages(for: job.wrappedValue.id)
                    } label: {
                        Label("Thêm ảnh/video", systemImage: "photo.on.rectangle")
                    }
                }

                if job.wrappedValue.images.isEmpty {
                    emptyState("Chưa chọn ảnh/video", systemImage: "photo.on.rectangle")
                } else {
                    VStack(spacing: 6) {
                        ForEach(job.wrappedValue.images, id: \.self) { imagePath in
                            mediaRow(imagePath: imagePath, showPath: true) {
                                model.removeImage(imagePath, from: job.wrappedValue.id)
                            }
                        }
                    }
                }
            }
    }

    private func scheduleEditor(job: Binding<ScheduleJob>) -> some View {
        let type = ScheduleType(rawValue: job.wrappedValue.schedule.type) ?? .daily
        return VStack(alignment: .leading, spacing: 10) {
            if type == .daily {
                HStack(alignment: .center, spacing: 14) {
                    DatePicker("Giờ gửi", selection: dailyTimeBinding(for: job), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .frame(width: 210)

                    dayToggleRow(job: job)
                }
            } else {
                DatePicker("Ngày giờ gửi", selection: onceDateBinding(for: job), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .frame(width: 330)
            }
        }
        .padding(.top, 2)
    }

    private func dayToggleRow(job: Binding<ScheduleJob>) -> some View {
        let days: [(Int, String)] = [(0, "T2"), (1, "T3"), (2, "T4"), (3, "T5"), (4, "T6"), (5, "T7"), (6, "CN")]
        return HStack(spacing: 6) {
            ForEach(days, id: \.0) { day, title in
                let isOn = (job.wrappedValue.schedule.days ?? [0, 1, 2, 3, 4, 5, 6]).contains(day)
                Button {
                    var selected = Set(job.wrappedValue.schedule.days ?? [0, 1, 2, 3, 4, 5, 6])
                    if selected.contains(day), selected.count > 1 {
                        selected.remove(day)
                    } else {
                        selected.insert(day)
                    }
                    job.wrappedValue.schedule.days = selected.sorted()
                } label: {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 28)
                        .foregroundStyle(isOn ? .white : .primary)
                        .background(isOn ? brandPrimary : fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isOn ? Color.clear : Color.secondary.opacity(0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
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
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                    .overlay(panelStroke)

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
                HStack(alignment: .top, spacing: 12) {
                    field("Người nhận") {
                        TextField("Tên hoặc số điện thoại trong Zalo", text: $model.recipient)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tệp test")
                            .font(.subheadline.weight(.medium))
                        Button {
                            model.chooseImages()
                        } label: {
                            Label("Chọn ảnh/video", systemImage: "photo.on.rectangle")
                        }
                    }
                    .frame(width: 160, alignment: .leading)
                }

                sectionBox("Tin nhắn test", systemImage: "text.bubble") {
                    editor(text: $model.message, minHeight: 118)
                }

                sectionBox("Ảnh/video test", systemImage: "paperclip") {
                    if model.testImagePaths.isEmpty {
                        emptyState("Chưa chọn ảnh/video", systemImage: "photo.on.rectangle")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(model.testImagePaths, id: \.self) { imagePath in
                                mediaRow(imagePath: imagePath, showPath: false) {
                                    model.removeTestImage(imagePath)
                                }
                            }
                        }
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
                        .foregroundStyle(warningOrange)
                }
                .disabled(model.currentTask != nil)
            }
        }
    }

    private var logCard: some View {
        panel("Nhật ký", systemImage: "terminal.fill") {
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
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                .overlay(panelStroke)
            }
        }
    }

    private func scheduleTypeBinding(for job: Binding<ScheduleJob>) -> Binding<ScheduleType> {
        Binding<ScheduleType>(
            get: {
                ScheduleType(rawValue: job.wrappedValue.schedule.type) ?? .daily
            },
            set: { newValue in
                job.wrappedValue.schedule.type = newValue.rawValue
                switch newValue {
                case .daily:
                    job.wrappedValue.schedule.at = LauncherModel.formatDailyTime(Date())
                    job.wrappedValue.schedule.days = [0, 1, 2, 3, 4, 5, 6]
                case .once:
                    job.wrappedValue.schedule.at = LauncherModel.formatOnceDate(Date().addingTimeInterval(3600))
                    job.wrappedValue.schedule.days = nil
                }
            }
        )
    }

    private func dailyTimeBinding(for job: Binding<ScheduleJob>) -> Binding<Date> {
        Binding<Date>(
            get: {
                LauncherModel.dailyDate(from: job.wrappedValue.schedule.at) ?? Date()
            },
            set: { date in
                job.wrappedValue.schedule.at = LauncherModel.formatDailyTime(date)
            }
        )
    }

    private func onceDateBinding(for job: Binding<ScheduleJob>) -> Binding<Date> {
        Binding<Date>(
            get: {
                LauncherModel.onceDate(from: job.wrappedValue.schedule.at) ?? Date().addingTimeInterval(3600)
            },
            set: { date in
                job.wrappedValue.schedule.at = LauncherModel.formatOnceDate(date)
            }
        )
    }

    private func scheduleSummary(for job: ScheduleJob) -> String {
        let type = ScheduleType(rawValue: job.schedule.type) ?? .daily
        switch type {
        case .daily:
            let days = job.schedule.days ?? [0, 1, 2, 3, 4, 5, 6]
            let dayText = days.count == 7 ? "hằng ngày" : days.map(dayLabel).joined(separator: ", ")
            return "\(job.schedule.at) · \(dayText)"
        case .once:
            guard let date = LauncherModel.onceDate(from: job.schedule.at) else {
                return "Một lần"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "vi_VN")
            formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
            formatter.dateFormat = "HH:mm dd/MM/yyyy"
            return formatter.string(from: date)
        }
    }

    private func dayLabel(_ day: Int) -> String {
        switch day {
        case 0: return "T2"
        case 1: return "T3"
        case 2: return "T4"
        case 3: return "T5"
        case 4: return "T6"
        case 5: return "T7"
        case 6: return "CN"
        default: return "-"
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
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
            return successGreen
        case .some(false):
            return warningOrange
        case .none:
            return .secondary
        }
    }

    private func panel<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(brandPrimary)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
    }

    private func statusPill(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
    }

    private func statusBanner(title: String, detail: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
    }

    private func sectionBox<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
    }

    private func mediaRow(imagePath: String, showPath: Bool, onRemove: @escaping () -> Void) -> some View {
        let mediaKind = LauncherModel.mediaKind(for: imagePath)
        return HStack(spacing: 10) {
            Image(systemName: mediaKind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(brandPrimary)
                .frame(width: 30, height: 30)
                .background(brandPrimarySoft)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: imagePath).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(mediaKind.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(brandPrimary)
                    if showPath {
                        Text(imagePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(9)
        .background(fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .overlay(panelStroke)
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
                .background(fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                .overlay(panelStroke)
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            .overlay(panelStroke)
    }

    private func plainEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            .overlay(panelStroke)
    }
}
