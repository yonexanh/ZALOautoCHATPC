import AppKit
import ApplicationServices
import Foundation

enum AutomationError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

struct ElementInfo: Codable {
    let role: String
    let title: String
    let value: String
    let actions: [String]
    let position: PointInfo?
    let size: SizeInfo?
}

struct PointInfo: Codable {
    let x: Double
    let y: Double
}

struct SizeInfo: Codable {
    let width: Double
    let height: Double
}

struct ProbeResult: Codable {
    let appRunning: Bool
    let focusedWindowTitle: String
    let searchField: ElementInfo?
    let messageInput: ElementInfo?
    let imageButton: ElementInfo?
    let attachmentButton: ElementInfo?
}

struct AccessibilityTrustReport: Codable {
    let trusted: Bool
    let processName: String
    let executablePath: String
    let bundleIdentifier: String?
    let message: String
}

struct SendRequest {
    let recipient: String
    let message: String?
    let images: [String]
}

final class ZaloAutomation {
    private let bundleIdentifier = "com.vng.zalo"

    func accessibilityStatus(prompt: Bool) -> AccessibilityTrustReport {
        if prompt && !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            usleep(250_000)
        }

        let trusted = AXIsProcessTrusted()
        let processName = helperProcessName()
        let executablePath = helperExecutablePath()
        let message: String
        if trusted {
            message = "Accessibility đã sẵn sàng cho \(processName)."
        } else {
            message = "Chưa cấp quyền Accessibility cho \(processName). Hãy bật đúng app/process ở đường dẫn bên dưới."
        }

        return AccessibilityTrustReport(
            trusted: trusted,
            processName: processName,
            executablePath: executablePath,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            message: message
        )
    }

    func probe() throws -> ProbeResult {
        try ensureAccessibilityTrusted(prompt: false)
        guard let app = runningZaloApplication() else {
            return ProbeResult(
                appRunning: false,
                focusedWindowTitle: "",
                searchField: nil,
                messageInput: nil,
                imageButton: nil,
                attachmentButton: nil
            )
        }

        activate(app)
        let window = try mainWindow(for: app)
        let all = try interactiveDescendants(of: window)

        return ProbeResult(
            appRunning: true,
            focusedWindowTitle: stringAttribute(kAXTitleAttribute, of: window) ?? "",
            searchField: bestSearchField(in: all).map(info(for:)),
            messageInput: bestProbeMessageInput(in: all).map(info(for:)),
            imageButton: bestImageButton(in: all).map(info(for:)),
            attachmentButton: bestAttachmentButton(in: all).map(info(for:))
        )
    }

    func send(_ request: SendRequest) throws {
        try ensureAccessibilityTrusted(prompt: false)
        guard let app = runningZaloApplication() else {
            throw AutomationError.message("Zalo chưa chạy. Hãy mở Zalo PC và đăng nhập trước.")
        }

        activate(app)
        let window = try mainWindow(for: app)
        try selectRecipient(named: request.recipient, in: window)

        if !request.images.isEmpty {
            for imagePath in request.images {
                try attachMedia(at: imagePath, app: app)
            }
        }

        if let message = request.message, !message.isEmpty {
            try setComposerText(message, in: app)
        }

        try pressKey(keyCode: 36)
    }

    func openChat(recipient: String) throws {
        try ensureAccessibilityTrusted(prompt: false)
        guard let app = runningZaloApplication() else {
            throw AutomationError.message("Zalo chưa chạy. Hãy mở Zalo PC và đăng nhập trước.")
        }

        activate(app)
        let window = try mainWindow(for: app)
        try selectRecipient(named: recipient, in: window)
    }

    private func selectRecipient(named recipient: String, in window: AXUIElement) throws {
        let elements = try interactiveDescendants(of: window)
        if let field = bestSearchField(in: elements) {
            try click(element: field)
            try replaceFocusedText(with: recipient)
        } else {
            try focusSearchFieldByPosition(in: window)
            try replaceFocusedText(with: recipient)
        }
        usleep(700_000)
        do {
            try waitForSearchState(timeoutSeconds: 2.5)
        } catch {
            throw AutomationError.message("Không tìm thấy người nhận '\(recipient)' trong kết quả tìm kiếm.")
        }
        try pressKey(keyCode: 125)
        try pressKey(keyCode: 36)
        usleep(700_000)
    }

    private func setComposerText(_ text: String, in app: NSRunningApplication) throws {
        let window = try mainWindow(for: app)
        let elements = try interactiveDescendants(of: window)
        if let composer = bestProbeMessageInput(in: elements) {
            try click(element: composer)
        } else {
            try clickComposerByPosition(in: window)
        }
        usleep(150_000)
        writeClipboard(text)
        try pressKey(keyCode: 9, modifiers: [.maskCommand])
        usleep(250_000)
    }

    private func attachMedia(at mediaPath: String, app: NSRunningApplication) throws {
        let standardizedPath = URL(fileURLWithPath: mediaPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            throw AutomationError.message("Không tìm thấy tệp media: \(standardizedPath)")
        }

        if shouldAttachAsFile(standardizedPath) {
            try attachFileWithOpenPanel(at: standardizedPath, app: app)
            return
        }

        do {
            try attachImageWithOpenPanel(at: standardizedPath, app: app)
        } catch {
            let pickerError = automationErrorMessage(from: error)
            try dismissOpenPanelsIfPresent()
            guard canReadImageFile(standardizedPath) else {
                throw AutomationError.message("Không đính kèm được video/media. Picker: \(pickerError). Video cần được Zalo nhận qua hộp chọn file.")
            }
            do {
                try attachImageViaClipboard(at: standardizedPath, app: app)
            } catch {
                let clipboardError = automationErrorMessage(from: error)
                throw AutomationError.message("Không đính kèm được media. Picker: \(pickerError). Clipboard: \(clipboardError)")
            }
        }
    }

    private func attachFileWithOpenPanel(at filePath: String, app: NSRunningApplication) throws {
        let window = try mainWindow(for: app)
        var clickedFileMenuItem = false
        if let existingFileMenuItem = try waitForZaloElement(timeoutSeconds: 0.2, matching: isChooseFileMenuItem) {
            try click(element: existingFileMenuItem)
            clickedFileMenuItem = true
        } else {
            let elements = try interactiveDescendants(of: window)
            if let button = bestAttachmentButton(in: elements) {
                try click(element: button)
            } else {
                try clickAttachmentButtonByPosition(in: window)
            }
            usleep(300_000)
        }

        if !clickedFileMenuItem {
            if let fileMenuItem = try waitForZaloElement(timeoutSeconds: 2.0, matching: isChooseFileMenuItem) {
                try click(element: fileMenuItem)
            } else {
                try clickChooseFileMenuByPosition(in: window)
            }
        }
        usleep(500_000)

        guard let openPanel = try waitForOpenPanel(timeoutSeconds: 4.0) else {
            throw AutomationError.message("Không mở được hộp thoại chọn file.")
        }
        try focusOrClick(openPanel)
        try choosePathInOpenPanel(filePath)
        usleep(900_000)
    }

    private func attachImageWithOpenPanel(at imagePath: String, app: NSRunningApplication) throws {
        let window = try mainWindow(for: app)
        let elements = try interactiveDescendants(of: window)
        if let button = bestImageButton(in: elements) {
            try click(element: button)
        } else {
            try clickImageButtonByPosition(in: window)
        }
        usleep(350_000)

        if try waitForOpenPanel(timeoutSeconds: 2.0) == nil {
            try clickImageButtonByPosition(in: window)
            usleep(500_000)
        }

        guard let openPanel = try waitForOpenPanel(timeoutSeconds: 4.0) else {
            throw AutomationError.message("Không mở được hộp thoại chọn media.")
        }
        try focusOrClick(openPanel)
        try choosePathInOpenPanel(imagePath)
        usleep(900_000)
    }

    private func choosePathInOpenPanel(_ path: String) throws {
        guard let openPanel = try waitForOpenPanel(timeoutSeconds: 1.0) else {
            throw AutomationError.message("Không tìm thấy hộp thoại chọn file.")
        }
        try focusOrClick(openPanel)
        var gotoWindow: AXUIElement?
        for _ in 0..<3 {
            try pressKey(keyCode: 5, modifiers: [.maskCommand, .maskShift])
            usleep(250_000)
            gotoWindow = try waitForGoToWindow(timeoutSeconds: 1.2)
            if gotoWindow != nil {
                break
            }
            try focusOrClick(openPanel)
        }

        guard let gotoWindow else {
            throw AutomationError.message("Không mở được hộp thoại nhập đường dẫn media.")
        }

        let gotoField = try require(firstElement(
            matching: { element in
                self.stringAttribute("AXIdentifier", of: element) == "PathTextField"
                    || self.role(of: element) == kAXTextFieldRole as String
            },
            in: descendants(of: gotoWindow)
        ), "Không tìm thấy ô đường dẫn trong hộp thoại chọn media.")
        try focusOrClick(gotoField)
        try replaceFocusedText(with: path)

        try pressKey(keyCode: 36)
        usleep(450_000)

        if let refreshedPanel = try waitForOpenPanel(timeoutSeconds: 1.5),
           let openButton = button(namedAnyOf: ["mo", "open"], in: refreshedPanel) {
            try click(element: openButton)
        } else {
            try pressKey(keyCode: 36)
        }
    }

    private func attachImageViaClipboard(at imagePath: String, app: NSRunningApplication) throws {
        let window = try mainWindow(for: app)
        if let composer = bestProbeMessageInput(in: try interactiveDescendants(of: window)) {
            try click(element: composer)
        } else {
            try clickComposerByPosition(in: window)
        }

        guard let image = NSImage(contentsOfFile: imagePath) else {
            throw AutomationError.message("File không đọc được như ảnh: \(imagePath)")
        }

        let url = URL(fileURLWithPath: imagePath)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url), url.pathExtension.localizedCaseInsensitiveContains("png") {
            item.setData(data, forType: .png)
        }
        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        guard pasteboard.writeObjects([item]) else {
            throw AutomationError.message("Không ghi được ảnh vào clipboard.")
        }

        try pressKey(keyCode: 9, modifiers: [.maskCommand])
        usleep(1_000_000)
    }

    private func canReadImageFile(_ path: String) -> Bool {
        NSImage(contentsOfFile: path) != nil
    }

    private func shouldAttachAsFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpeg", "mpg"]
        return videoExtensions.contains(ext)
    }

    private func refreshedMainWindow() throws -> AXUIElement {
        guard let app = runningZaloApplication() else {
            throw AutomationError.message("Zalo đã đóng trong lúc thao tác.")
        }
        return try mainWindow(for: app)
    }

    private func waitForSearchState(timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let window = try refreshedMainWindow()
            if containsEmptySearchState(in: window) {
                throw AutomationError.message("Không tìm thấy người nhận trong kết quả tìm kiếm.")
            }
            usleep(120_000)
        }
    }

    private func containsEmptySearchState(in window: AXUIElement) -> Bool {
        descendants(of: window).contains { element in
            let labelText = label(for: element) ?? ""
            return labelText.localizedCaseInsensitiveContains("Không tìm thấy kết quả")
        }
    }

    private func interactiveDescendants(of window: AXUIElement) throws -> [AXUIElement] {
        var elements = descendants(of: window)
        if hasCoreControls(in: elements) {
            return elements
        }

        try wakeZaloWebView(in: window)
        elements = descendants(of: window)
        return elements
    }

    private func hasCoreControls(in elements: [AXUIElement]) -> Bool {
        bestSearchField(in: elements) != nil
            || bestProbeMessageInput(in: elements) != nil
            || bestImageButton(in: elements) != nil
            || bestAttachmentButton(in: elements) != nil
    }

    private func wakeZaloWebView(in window: AXUIElement) throws {
        try focusSearchFieldByPosition(in: window)
        usleep(350_000)
    }

    private func focusSearchFieldByPosition(in window: AXUIElement) throws {
        let frame = try windowFrame(window)
        let point = CGPoint(
            x: frame.minX + min(160, max(90, frame.width * 0.18)),
            y: frame.minY + 40
        )
        try click(at: point)
    }

    private func clickComposerByPosition(in window: AXUIElement) throws {
        let frame = try windowFrame(window)
        let point = CGPoint(
            x: min(max(frame.minX + 420, frame.minX + frame.width * 0.45), frame.maxX - 130),
            y: frame.maxY - 36
        )
        try click(at: point)
    }

    private func clickImageButtonByPosition(in window: AXUIElement) throws {
        let frame = try windowFrame(window)
        let point = CGPoint(
            x: min(max(frame.minX + 462, frame.minX + frame.width * 0.50), frame.maxX - 210),
            y: frame.maxY - 87
        )
        try click(at: point)
    }

    private func clickAttachmentButtonByPosition(in window: AXUIElement) throws {
        let frame = try windowFrame(window)
        let point = CGPoint(
            x: min(max(frame.minX + 505, frame.minX + frame.width * 0.54), frame.maxX - 170),
            y: frame.maxY - 87
        )
        try click(at: point)
    }

    private func clickChooseFileMenuByPosition(in window: AXUIElement) throws {
        let frame = try windowFrame(window)
        let point = CGPoint(
            x: min(max(frame.minX + 580, frame.minX + frame.width * 0.58), frame.maxX - 120),
            y: frame.maxY - 215
        )
        try click(at: point)
    }

    private func focusOrClick(_ element: AXUIElement) throws {
        if position(of: element) != nil {
            try click(element: element)
        } else {
            try focus(element)
        }
    }

    private func bestSearchField(in elements: [AXUIElement]) -> AXUIElement? {
        elements
            .filter { role(of: $0) == kAXTextFieldRole as String }
            .sorted(by: compareVisualOrder)
            .first
    }

    private func bestSettableMessageInput(in elements: [AXUIElement]) -> AXUIElement? {
        bottomMost(elements.filter { element in
            let roleName = role(of: element) ?? ""
            if roleName == kAXTextAreaRole as String && supportsValueInput(element) {
                return true
            }

            let labelText = label(for: element) ?? ""
            return supportsValueInput(element) && labelText.localizedCaseInsensitiveContains("Nhập @, tin nhắn tới")
        })
    }

    private func bestProbeMessageInput(in elements: [AXUIElement]) -> AXUIElement? {
        if let exact = bestSettableMessageInput(in: elements) {
            return exact
        }

        return bottomMost(elements.filter { element in
            let labelText = label(for: element) ?? ""
            return labelText.localizedCaseInsensitiveContains("Nhập @, tin nhắn tới")
        })
    }

    private func bestImageButton(in elements: [AXUIElement]) -> AXUIElement? {
        bestLabeledClickTarget(
            in: elements,
            matching: { self.normalize($0).contains("gui hinh anh") }
        )
    }

    private func bestAttachmentButton(in elements: [AXUIElement]) -> AXUIElement? {
        bestLabeledClickTarget(
            in: elements,
            matching: { self.normalize($0).contains("dinh kem file") }
        )
    }

    private func isChooseFileMenuItem(_ element: AXUIElement) -> Bool {
        let normalizedLabel = normalize(label(for: element) ?? "")
        return normalizedLabel == "chon file" || normalizedLabel.contains("chon file")
    }

    private func bestLabeledClickTarget(
        in elements: [AXUIElement],
        matching predicate: (String) -> Bool
    ) -> AXUIElement? {
        let matches = elements.filter { element in
            guard let labelText = label(for: element), predicate(labelText) else {
                return false
            }
            return position(of: element) != nil
        }

        if let directlyClickable = matches.first(where: { actions(of: $0).contains(kAXPressAction as String) }) {
            return directlyClickable
        }
        return matches.first
    }

    private func hasPressAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        while let item = current {
            if actions(of: item).contains(kAXPressAction as String) {
                return true
            }
            current = parent(of: item)
        }
        return false
    }

    private func press(elementOrAncestor element: AXUIElement) throws {
        var current: AXUIElement? = element
        while let item = current {
            if actions(of: item).contains(kAXPressAction as String) {
                let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard error == .success else {
                    throw AutomationError.message("Không thể bấm vào phần tử Zalo. Mã lỗi: \(error.rawValue)")
                }
                return
            }
            current = parent(of: item)
        }
        throw AutomationError.message("Không tìm thấy phần tử nào có thể bấm.")
    }

    private func runningZaloApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private func mainWindow(for app: NSRunningApplication) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focused = copyElementAttribute(kAXFocusedWindowAttribute, of: appElement) {
            return focused
        }
        if let main = copyElementAttribute(kAXMainWindowAttribute, of: appElement) {
            return main
        }
        if let firstWindow = copyElementArrayAttribute(kAXWindowsAttribute, of: appElement).first {
            return firstWindow
        }

        throw AutomationError.message("Không tìm thấy cửa sổ chính của Zalo.")
    }

    private func waitForWindow(id: String, timeoutSeconds: Double) throws -> AXUIElement? {
        try waitForElement(timeoutSeconds: timeoutSeconds) { element in
            self.stringAttribute("AXIdentifier", of: element) == id
        }
    }

    private func waitForOpenPanel(timeoutSeconds: Double) throws -> AXUIElement? {
        try waitForElement(timeoutSeconds: timeoutSeconds, matching: isOpenPanelLike)
    }

    private func waitForGoToWindow(timeoutSeconds: Double) throws -> AXUIElement? {
        try waitForElement(timeoutSeconds: timeoutSeconds, matching: isGoToWindowLike)
    }

    private func waitForElement(
        timeoutSeconds: Double,
        matching predicate: @escaping (AXUIElement) -> Bool
    ) throws -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            guard let app = runningZaloApplication() else { break }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var roots = [appElement]
            roots.append(contentsOf: copyElementArrayAttribute(kAXWindowsAttribute, of: appElement))
            if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute, of: appElement) {
                roots.append(focusedWindow)
            }

            if let match = roots.lazy.flatMap({ self.descendants(of: $0) }).first(where: predicate) {
                return match
            }
            usleep(100_000)
        }
        return nil
    }

    private func waitForZaloElement(
        timeoutSeconds: Double,
        matching predicate: @escaping (AXUIElement) -> Bool
    ) throws -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            guard let app = runningZaloApplication() else { break }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var roots = [appElement]
            roots.append(contentsOf: copyElementArrayAttribute(kAXWindowsAttribute, of: appElement))
            if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute, of: appElement) {
                roots.append(focusedWindow)
            }

            if let match = roots.lazy.flatMap({ self.descendants(of: $0) }).first(where: predicate) {
                return match
            }
            usleep(100_000)
        }
        return nil
    }

    private func isOpenPanelLike(_ element: AXUIElement) -> Bool {
        if stringAttribute("AXIdentifier", of: element) == "open-panel" {
            return true
        }

        let roleName = role(of: element) ?? ""
        guard roleName == kAXWindowRole as String || roleName == kAXSheetRole as String else {
            return false
        }

        let ownLabel = normalize(label(for: element) ?? "")
        if ownLabel.contains("chon hinh anh") || ownLabel.contains("choose image") || ownLabel == "open" {
            return true
        }

        let labels = descendants(of: element, maxDepth: 6)
            .compactMap(label(for:))
            .map { self.normalize($0) }
        return labels.contains("huy") && (labels.contains("mo") || labels.contains("open"))
    }

    private func isGoToWindowLike(_ element: AXUIElement) -> Bool {
        if stringAttribute("AXIdentifier", of: element) == "GoToWindow" {
            return true
        }

        let children = descendants(of: element, maxDepth: 6)
        if children.contains(where: { stringAttribute("AXIdentifier", of: $0) == "PathTextField" }) {
            return true
        }

        let roleName = role(of: element) ?? ""
        guard roleName == kAXWindowRole as String || roleName == kAXSheetRole as String else {
            return false
        }

        let ownLabel = normalize(label(for: element) ?? "")
        return ownLabel.contains("go to") || ownLabel.contains("di toi")
    }

    private func button(namedAnyOf normalizedNames: Set<String>, in root: AXUIElement) -> AXUIElement? {
        descendants(of: root, maxDepth: 10).first { element in
            guard role(of: element) == kAXButtonRole as String else {
                return false
            }
            let buttonLabel = normalize(label(for: element) ?? "")
            return normalizedNames.contains(buttonLabel)
        }
    }

    private func dismissOpenPanelsIfPresent() throws {
        let hasOpenPanel = try waitForOpenPanel(timeoutSeconds: 0.2) != nil
        let hasGoToWindow = try waitForGoToWindow(timeoutSeconds: 0.2) != nil
        if hasOpenPanel || hasGoToWindow {
            try pressKey(keyCode: 53)
            usleep(250_000)
            try pressKey(keyCode: 53)
            usleep(250_000)
        }
    }

    private func ensureAccessibilityTrusted(prompt: Bool) throws {
        if AXIsProcessTrusted() {
            return
        }

        if prompt {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            usleep(250_000)
        }

        guard AXIsProcessTrusted() else {
            let path = helperExecutablePath()
            throw AutomationError.message("Chưa cấp quyền Accessibility cho process đang điều khiển Zalo. Hãy bật quyền cho '\(helperProcessName())' tại: \(path).")
        }
    }

    private func helperExecutablePath() -> String {
        if let path = Bundle.main.executableURL?.path, !path.isEmpty {
            return path
        }
        if let firstArgument = CommandLine.arguments.first, !firstArgument.isEmpty {
            return URL(fileURLWithPath: firstArgument).standardizedFileURL.path
        }
        return ProcessInfo.processInfo.processName
    }

    private func helperProcessName() -> String {
        let path = helperExecutablePath()
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return ProcessInfo.processInfo.processName
    }

    private func activate(_ app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
        usleep(400_000)
    }

    private func descendants(of root: AXUIElement, maxDepth: Int = 20) -> [AXUIElement] {
        var output: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth else { return }
            output.append(element)
            for child in copyElementArrayAttribute(kAXChildrenAttribute, of: element) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return output
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        copyElementAttribute(kAXParentAttribute, of: element)
    }

    private func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, of: element)
    }

    private func label(for element: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
            if let text = stringAttribute(attr, of: element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private func info(for element: AXUIElement) -> ElementInfo {
        ElementInfo(
            role: role(of: element) ?? "",
            title: stringAttribute(kAXTitleAttribute, of: element) ?? "",
            value: label(for: element) ?? "",
            actions: actions(of: element),
            position: position(of: element).map { PointInfo(x: $0.x, y: $0.y) },
            size: size(of: element).map { SizeInfo(width: $0.width, height: $0.height) }
        )
    }

    private func supportsValueInput(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard error == .success else {
            return false
        }
        return settable.boolValue
    }

    private func actions(of element: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        let error = AXUIElementCopyActionNames(element, &actionsRef)
        guard error == .success, let actionsArray = actionsRef as? [String] else {
            return []
        }
        return actionsArray
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        guard
            let rawValue = copyAttribute(kAXPositionAttribute, of: element),
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func size(of element: AXUIElement) -> CGSize? {
        guard
            let rawValue = copyAttribute(kAXSizeAttribute, of: element),
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func copyAttribute(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        guard error == .success else { return nil }
        return result
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        if let stringValue = copyAttribute(attribute, of: element) as? String {
            return stringValue
        }
        if let attributedString = copyAttribute(attribute, of: element) as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func windowFrame(_ window: AXUIElement) throws -> CGRect {
        guard let position = position(of: window), let size = size(of: window) else {
            throw AutomationError.message("Không xác định được vị trí/kích thước cửa sổ Zalo.")
        }
        return CGRect(origin: position, size: size)
    }

    private func copyElementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard
            let rawValue = copyAttribute(attribute, of: element),
            CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(attribute, of: element) as? [AXUIElement] ?? []
    }

    private func setValue(_ element: AXUIElement, to value: String) throws {
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard error == .success else {
            throw AutomationError.message("Không thể gán nội dung cho phần tử Zalo. Mã lỗi: \(error.rawValue)")
        }
    }

    private func replaceFocusedText(with text: String) throws {
        try pressKey(keyCode: 0, modifiers: [.maskCommand])
        usleep(80_000)
        writeClipboard(text)
        try pressKey(keyCode: 9, modifiers: [.maskCommand])
        usleep(250_000)
    }

    private func focus(_ element: AXUIElement) throws {
        let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard error == .success else {
            throw AutomationError.message("Không thể focus vào phần tử Zalo. Mã lỗi: \(error.rawValue)")
        }
    }

    private func pressKey(keyCode: CGKeyCode, modifiers: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw AutomationError.message("Không tạo được nguồn sự kiện bàn phím.")
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = modifiers
        keyUp?.flags = modifiers
        keyDown?.post(tap: .cghidEventTap)
        usleep(40_000)
        keyUp?.post(tap: .cghidEventTap)
        usleep(80_000)
    }

    private func click(element: AXUIElement) throws {
        let point: CGPoint
        if let position = position(of: element), let size = size(of: element) {
            point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
        } else if let position = position(of: element) {
            point = position
        } else {
            throw AutomationError.message("Không xác định được vị trí để click vào ô nhập tin nhắn.")
        }
        try click(at: point)
    }

    private func click(at point: CGPoint) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw AutomationError.message("Không tạo được nguồn sự kiện chuột.")
        }

        let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        moved?.post(tap: .cghidEventTap)
        usleep(40_000)
        down?.post(tap: .cghidEventTap)
        usleep(40_000)
        up?.post(tap: .cghidEventTap)
        usleep(80_000)
    }

    private func writeClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func compareVisualOrder(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        let leftPoint = position(of: lhs) ?? CGPoint(
            x: CGFloat.greatestFiniteMagnitude,
            y: CGFloat.greatestFiniteMagnitude
        )
        let rightPoint = position(of: rhs) ?? CGPoint(
            x: CGFloat.greatestFiniteMagnitude,
            y: CGFloat.greatestFiniteMagnitude
        )
        if leftPoint.y == rightPoint.y {
            return leftPoint.x < rightPoint.x
        }
        return leftPoint.y < rightPoint.y
    }

    private func bottomMost(_ elements: [AXUIElement]) -> AXUIElement? {
        elements.sorted { lhs, rhs in
            let leftPoint = position(of: lhs) ?? .zero
            let rightPoint = position(of: rhs) ?? .zero
            if leftPoint.y == rightPoint.y {
                return leftPoint.x < rightPoint.x
            }
            return leftPoint.y > rightPoint.y
        }.first
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "vi_VN"))
            .replacingOccurrences(of: "Đ", with: "D")
            .replacingOccurrences(of: "đ", with: "d")
            .lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AutomationError.message(message) }
        return value
    }

    private func firstElement(
        matching predicate: (AXUIElement) -> Bool,
        in elements: [AXUIElement]
    ) -> AXUIElement? {
        elements.first(where: predicate)
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let text = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

let automationCommands: Set<String> = [
    "accessibility-status",
    "request-accessibility",
    "probe",
    "open-chat",
    "send",
]

let automationUsage = "Dùng: accessibility-status | request-accessibility | probe | open-chat --recipient <tên> | send --recipient <tên> [--message <text>] [--image <path> ...]"

func isAutomationCommand(_ command: String) -> Bool {
    automationCommands.contains(command)
}

func automationErrorMessage(from error: Error) -> String {
    if let automationError = error as? AutomationError {
        return automationError.description
    }
    return error.localizedDescription
}

@discardableResult
func runAutomationCommand(arguments: [String]) throws -> Bool {
    guard let command = arguments.first, isAutomationCommand(command) else {
        return false
    }

    let automation = ZaloAutomation()

    switch command {
    case "accessibility-status":
        try printJSON(automation.accessibilityStatus(prompt: false))
    case "request-accessibility":
        try printJSON(automation.accessibilityStatus(prompt: true))
    case "probe":
        try printJSON(automation.probe())
    case "open-chat":
        let request = try parseSendRequest(arguments: Array(arguments.dropFirst()))
        try automation.openChat(recipient: request.recipient)
    case "send":
        let request = try parseSendRequest(arguments: Array(arguments.dropFirst()))
        try automation.send(request)
    default:
        return false
    }

    return true
}

func parseSendRequest(arguments: [String]) throws -> SendRequest {
    var recipient: String?
    var message: String?
    var images: [String] = []

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--recipient":
            index += 1
            guard index < arguments.count else {
                throw AutomationError.message("Thiếu giá trị cho --recipient")
            }
            recipient = arguments[index]
        case "--message":
            index += 1
            guard index < arguments.count else {
                throw AutomationError.message("Thiếu giá trị cho --message")
            }
            message = arguments[index]
        case "--image":
            index += 1
            guard index < arguments.count else {
                throw AutomationError.message("Thiếu giá trị cho --image")
            }
            images.append(arguments[index])
        default:
            throw AutomationError.message("Tham số không hỗ trợ: \(argument)")
        }
        index += 1
    }

    guard let recipient, !recipient.isEmpty else {
        throw AutomationError.message("Cần cung cấp --recipient")
    }

    return SendRequest(recipient: recipient, message: message, images: images)
}
