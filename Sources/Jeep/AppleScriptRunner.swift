import AppKit

struct AppleScriptFailure: LocalizedError {
    /// OSA / Apple Event error number, when the failure came from a script.
    let code: Int?
    let message: String

    init(message: String, code: Int? = nil) {
        self.code = code
        self.message = message
    }

    /// errAEEventNotPermitted: the user has not allowed Jeep to control Safari.
    static let automationDeniedCode = -1743
    /// procNotFound: the target application is not running.
    static let applicationNotRunningCode = -600
    /// errAETimeout: Safari did not answer within the script's timeout.
    static let timeoutCode = -1712

    var isAutomationDenied: Bool {
        code == Self.automationDeniedCode
    }

    var errorDescription: String? {
        message
    }

    /// Replaces raw OSA messages for the failures a user can act on.
    static func userFacingMessage(code: Int?, fallback: String) -> String {
        switch code {
        case automationDeniedCode:
            return "Jeep isn’t allowed to control Safari. Allow it in System Settings → Privacy & Security → Automation."
        case applicationNotRunningCode:
            return "Safari is not running."
        case timeoutCode:
            return "Safari didn’t respond in time. Try again in a moment."
        default:
            return fallback
        }
    }
}

struct AppleScriptRunner {
    /// Bounds every Apple Event a script sends to Safari, so a hung Safari
    /// cannot freeze Jeep for the default two-minute Apple Event timeout.
    static let appleEventTimeoutSeconds = 5

    static func withTimeout(_ source: String) -> String {
        """
        with timeout of \(appleEventTimeoutSeconds) seconds
        \(source)
        end timeout
        """
    }

    func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: Self.withTimeout(source)) else {
            throw AppleScriptFailure(message: "The Safari control script could not be created.")
        }

        return try run(script)
    }

    /// Runs a precompiled script as-is; its source must already be wrapped
    /// with `withTimeout(_:)`.
    func run(_ script: NSAppleScript) throws -> String {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let rawMessage = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            throw AppleScriptFailure(
                message: AppleScriptFailure.userFacingMessage(
                    code: code,
                    fallback: rawMessage
                ),
                code: code
            )
        }

        return result.stringValue ?? ""
    }
}
