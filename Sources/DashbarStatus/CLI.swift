import Foundation

/// The `dashbar` command: reads the running app's snapshot and prints it. Kept here, apart from `main.swift`, so tests
/// can run it with fixture snapshots and a fake clock.
public enum DashbarCLI {
    /// Documented in `--help` and the README; scripts rely on them.
    public enum Exit: Int32 {
        case ok = 0
        /// No status file: Dashbar has never run, or it is older than 0.7.1.
        case missing = 2
        /// Dashbar isn't running, so the last status is out of date.
        case notRunning = 3
        /// The status file can't be read, or a newer Dashbar wrote it.
        case unreadable = 4
        case usage = 64
    }

    public struct Output: Equatable {
        public var code: Int32
        public var stdout: String
        public var stderr: String
    }

    public struct Context {
        public var reader: StatusReader
        public var format: StatusFormat
        public var environment: [String: String]
        /// The app's version, from the bundle the tool is in; nil when it runs outside one.
        public var version: String?

        public init(reader: StatusReader = StatusReader(), format: StatusFormat = StatusFormat(),
                    environment: [String: String] = ProcessInfo.processInfo.environment, version: String? = nil) {
            self.reader = reader
            self.format = format
            self.environment = environment
            self.version = version
        }
    }

    public static let help = """
    Usage: dashbar [status] [--json] [--local]
           dashbar line [--ascii] [--local]

    Shows what Dashbar knows about your agents, plan limits and dev servers. Dashbar has to be running; this
    command reads the status it saves and never reads agent logs itself.

    Commands:
      status          A few lines: agents that need you, agents working, plan limits (tightest first),
                      today's tokens and dev servers. The default.
      line            One short line for a tmux status bar or a shell prompt, like
                      "⚠ 1 needs you · 2 working · Claude 5h 55%".

    Options:
      --json          With status: print the status as JSON, with each limit's pace worked out now.
      --ascii         With line: use only ASCII characters.
      --local         Read the local build (Dashbar Local) instead of the release. DASHBAR_LOCAL=1 does the same.
                      Without it, the release is read if it is running, otherwise the local build.
      -h, --help      Show this help.
      -V, --version   Show the version.

    Exit status:
      0   Printed the current status.
      2   Dashbar hasn't saved a status yet. Open Dashbar 0.7.1 or later.
      3   Dashbar isn't running, so there's nothing current to show.
      4   The status file can't be read.
      64  The command or an option isn't recognised.
    """

    public static func run(_ arguments: [String], context: Context = Context()) -> Output {
        var command: String?
        var json = false, ascii = false, local = context.environment["DASHBAR_LOCAL"] == "1"
        for arg in arguments {
            switch arg {
            case "-h", "--help", "help": return Output(code: Exit.ok.rawValue, stdout: help + "\n", stderr: "")
            case "-V", "--version", "version":
                return Output(code: Exit.ok.rawValue, stdout: "dashbar \(context.version ?? "(not inside Dashbar.app)")\n", stderr: "")
            case "--json": json = true
            case "--ascii": ascii = true
            case "--local": local = true
            case "status", "line":
                guard command == nil else { return usage("Give one command, status or line.") }
                command = arg
            default:
                return usage(arg.hasPrefix("-") ? "\(arg) isn't an option." : "\(arg) isn't a command.")
            }
        }
        let mode = command ?? "status"
        if json && mode != "status" { return usage("--json goes with status.") }
        if ascii && mode != "line" { return usage("--ascii goes with line.") }

        if let file = context.environment["DASHBAR_STATUS_FILE"], !file.isEmpty {
            var reader = context.reader
            reader.overrideFile = file
            return print(reader.read(order: []), mode: mode, json: json, ascii: ascii, format: context.format)
        }
        let order: [StatusSnapshot.Copy] = local ? [.local] : [.release, .local]
        return print(context.reader.read(order: order), mode: mode, json: json, ascii: ascii, format: context.format)
    }

    private static func print(_ result: Result<StatusSnapshot, StatusReader.Failure>, mode: String, json: Bool, ascii: Bool,
                              format: StatusFormat) -> Output {
        switch result {
        case .success(let snapshot):
            if json {
                let data = (try? StatusSnapshot.encoder().encode(snapshot.withPaces(now: format.now))) ?? Data()
                return Output(code: Exit.ok.rawValue, stdout: String(decoding: data, as: UTF8.self) + "\n", stderr: "")
            }
            let text = mode == "line" ? format.line(snapshot, ascii: ascii) : format.status(snapshot)
            return Output(code: Exit.ok.rawValue, stdout: text + "\n", stderr: "")
        case .failure(.missing(let name)):
            return Output(code: Exit.missing.rawValue, stdout: "",
                          stderr: "dashbar: \(name) hasn't saved a status yet. Open \(name) 0.7.1 or later and try again.\n")
        case .failure(.notRunning(let name, let at)):
            let ago = StatusFormat.duration(format.now.timeIntervalSince(at))
            return Output(code: Exit.notRunning.rawValue, stdout: "",
                          stderr: "dashbar: \(name) isn't running, so there's nothing current to show (last update \(ago) ago). Open \(name) and try again.\n")
        case .failure(.unreadable(let path, let reason)):
            return Output(code: Exit.unreadable.rawValue, stdout: "",
                          stderr: "dashbar: Can't read \(path): \(reason).\n")
        }
    }

    private static func usage(_ problem: String) -> Output {
        Output(code: Exit.usage.rawValue, stdout: "", stderr: "dashbar: \(problem) Run dashbar --help to see what it takes.\n")
    }

    /// The version of the app bundle the running executable is inside (`Dashbar.app/Contents/Helpers/dashbar`), following
    /// a symlink on the PATH back to it. Nil outside a bundle.
    public static func bundleVersion(executable: URL) -> String? {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        let name = plist["CFBundleName"] as? String
        return name.map { "\(version) (\($0))" } ?? version
    }
}
