import Foundation
import DashbarStatus

// `dashbar`: prints what the running Dashbar knows. The work is in `DashbarCLI` (DashbarStatus), where tests reach it.
let version = Bundle.main.executableURL.flatMap(DashbarCLI.bundleVersion(executable:))
let output = DashbarCLI.run(Array(CommandLine.arguments.dropFirst()), context: DashbarCLI.Context(version: version))
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code)
