import Foundation

@main
struct ZaloHelperMain {
    static func main() {
        let exitCode: Int32
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard try runAutomationCommand(arguments: args) else {
                throw AutomationError.message(automationUsage)
            }
            exitCode = 0
        } catch {
            let message = automationErrorMessage(from: error)
            FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
            exitCode = 1
        }

        exit(exitCode)
    }
}
