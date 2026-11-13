import AerialKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let command: CLICommand
do {
    command = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(CLIExit.usage)
}

let env = Environment.live()
if let root = Environment.sandboxRoot(), command != .reapply(quiet: true) {
    FileHandle.standardError.write(Data((Copy.cliTestMode(root) + "\n").utf8))
}

do {
    try await Commands(env: env).run(command)
    exit(CLIExit.success)
} catch let error as CLIUsageError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(CLIExit.usage)
} catch {
    let message = (error as? LoopError)?.message ?? error.localizedDescription
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(CLIExit.code(for: error))
}
