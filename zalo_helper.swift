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
                imageButton: nil
            )
        }

        activate(app)
        let window = try mainWindow(for: app)
        let all = descendants(of: window)

        return ProbeResult(
            appRunning: true,
            focusedWindowTitle: stringAttribute(kAXTitleAttribute, of: window) ?? "",
            searchField: bestSearchField(in: all).map(info(for:)),
            messageInput: bestProbeMessageInput(in: all).map(info(for:)),
            imageButton: bestImageButton(in: all).map(info(for:))
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
                try attachImage(at: imagePath, app: app)
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
        let field = try require(bestSearchField(in: descendants(of: window)), "Không tìm thấy ô tìm kiếm của Zalo.")
        try focus(field)
        try setValue(field, to: recipient)
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
        let composer = try require(
            bestProbeMessageInput(in: descendants(of: window)),
            "Không tìm thấy ô nhập tin nhắn."
        )
        try click(element: composer)
        usleep(150_000)
        writeClipboard(text)
        try pressKey(keyCode: 9, modifiers: [.maskCommand])
        usleep(250_000)
    }

    private func attachImage(at imagePath: String, app: NSRunningApplication) throws {
        let standardizedPath = URL(fileURLWithPath: imagePath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            throw AutomationError.message("Không tìm thấy ảnh: \(standardizedPath)")
        }

        let window = try mainWindow(for: app)
        let button = try require(bestImageButton(in: descendants(of: window)), "Không tìm thấy nút Gửi hình ảnh.")
        try press(elementOrAncestor: button)
        usleep(700_000)

        try pressKey(keyCode: 5, modifiers: [.maskCommand, .maskShift])
        usleep(250_000)

        guard let gotoWindow = try waitForWindow(id: "GoToWindow", timeoutSeconds: 3.0) else {
            throw AutomationError.message("Không mở được hộp thoại nhập đường dẫn ảnh.")
        }

        let gotoField = try require(firstElement(
            matching: { role(of: $0) == kAXTextFieldRole as String },
            in: descendants(of: gotoWindow)
        ), "Không tìm thấy ô đường dẫn trong hộp thoại chọn ảnh.")
        try focus(gotoField)
        try setValue(gotoField, to: standardizedPath)
        usleep(150_000)

        try pressKey(keyCode: 36)
        usleep(250_000)
        try pressKey(keyCode: 36)
        usleep(900_000)
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
        elements.first { element in
            let labelText = label(for: element) ?? ""
            guard labelText.localizedCaseInsensitiveContains("Gửi hình ảnh") else {
                return false
            }
            return actions(of: element).contains(kAXPressAction as String) || hasPressAncestor(element)
        }
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
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            guard let app = runningZaloApplication() else { break }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let windows = copyElementArrayAttribute(kAXWindowsAttribute, of: appElement)
            if let match = windows.first(where: { stringAttribute("AXIdentifier", of: $0) == id }) {
                return match
            }
            usleep(100_000)
        }
        return nil
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
