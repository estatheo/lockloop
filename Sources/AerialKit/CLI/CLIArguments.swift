import Foundation

/// The CLI's commands, parsed by hand so building needs no dependencies.
public enum CLICommand: Equatable, Sendable {
    case set(file: String, fit: FitMode, download: String?, keep: Bool)
    case restore
    case status(json: Bool)
    case keep(on: Bool)
    case reapply(quiet: Bool)
    case help
}

public enum CLIExit {
    public static let success: Int32 = 0
    public static let failure: Int32 = 1
    public static let usage: Int32 = 2
    public static let unsupported: Int32 = 3
    public static let needsDownload: Int32 = 4

    public static func code(for error: Error) -> Int32 {
        switch error as? LoopError {
        case .unsupportedLayout?: return unsupported
        case .needsDownload?: return needsDownload
        default: return failure
        }
    }
}

public struct CLIUsageError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public enum CLIArguments {
    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let command = args.first else { return .help }
        var rest = Array(args.dropFirst())

        func takeFlag(_ name: String) -> Bool {
            if let i = rest.firstIndex(of: name) { rest.remove(at: i); return true }
            return false
        }
        func takeValue(_ name: String) throws -> String? {
            guard let i = rest.firstIndex(of: name) else { return nil }
            guard i + 1 < rest.count, !rest[i + 1].hasPrefix("--") else { throw CLIUsageError(message: Copy.cliMissingArgument("value for \(name)")) }
            let value = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
            return value
        }
        func finish() throws {
            if let unknown = rest.first(where: { $0.hasPrefix("-") }) { throw CLIUsageError(message: Copy.cliUnknownOption(unknown)) }
            if let extra = rest.first { throw CLIUsageError(message: Copy.cliUnknownOption(extra)) }
        }

        switch command {
        case "help", "--help", "-h":
            return .help
        case "set":
            let fill = takeFlag("--fill")
            let fit = takeFlag("--fit")
            if fill && fit { throw CLIUsageError(message: Copy.cliUnknownOption("--fit --fill")) }
            let keep = takeFlag("--keep")
            let download = try takeValue("--download")
            guard let fileIndex = rest.firstIndex(where: { !$0.hasPrefix("-") }) else {
                throw CLIUsageError(message: Copy.cliMissingArgument("file"))
            }
            let file = rest.remove(at: fileIndex)
            try finish()
            return .set(file: file, fit: fill ? .fill : .fit, download: download, keep: keep)
        case "restore":
            try finish()
            return .restore
        case "status":
            let json = takeFlag("--json")
            try finish()
            return .status(json: json)
        case "keep":
            guard let value = rest.first else { throw CLIUsageError(message: Copy.cliMissingArgument("on or off")) }
            rest.removeFirst()
            try finish()
            switch value {
            case "on": return .keep(on: true)
            case "off": return .keep(on: false)
            default: throw CLIUsageError(message: Copy.cliUnknownOption(value))
            }
        case "reapply":
            let quiet = takeFlag("--quiet")
            try finish()
            return .reapply(quiet: quiet)
        default:
            throw CLIUsageError(message: Copy.cliUnknownCommand(command))
        }
    }
}
