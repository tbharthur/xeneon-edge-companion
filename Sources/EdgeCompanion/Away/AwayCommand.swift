import EdgeCore
import Foundation

/// Files shared by the running app and the `--away` command.
enum AwayFiles {
  static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/EdgeCompanion/OfficeAway", isDirectory: true)
  /// Rewritten in place every few seconds by the app: liveness plus a status line.
  static let heartbeat = directory.appendingPathComponent("heartbeat")
  static let request = directory.appendingPathComponent("request")
  static let response = directory.appendingPathComponent("response")
  static let state = directory.appendingPathComponent("state.json")

  static func ensureDirectory() {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// Write-then-rename, so a reader never sees half a file and the directory watcher fires.
  static func writeAtomically(_ text: String, to url: URL) {
    try? Data(text.utf8).write(to: url, options: .atomic)
  }

  static func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func age(of url: URL) -> TimeInterval? {
    guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
    return Date().timeIntervalSince(date)
  }
}

/// `EdgeCompanion --away blank|unblank|status`: Home Assistant's office auto-off reaches the app
/// through this (tools/office-away in Arthur's assistant repo). Exit status: 0 handled (including
/// "ignored, someone is at the desk"), 3 the app is not running, 4 no answer, 5 the app can't
/// watch for input so it refused to go dark, 64 usage.
enum AwayCommand {
  static let flag = "--away"

  static func run(_ args: [String]) -> Int32 {
    switch args.first {
    case "blank": return send(.blank)
    case "unblank": return send(.unblank)
    case "status": return status()
    default:
      FileHandle.standardError.write(Data("usage: EdgeCompanion --away blank|unblank|status\n".utf8))
      return 64
    }
  }

  private static func send(_ command: AwayMessage.Command) -> Int32 {
    guard let age = AwayFiles.age(of: AwayFiles.heartbeat), age < AwayMessage.heartbeatStaleAfter else {
      FileHandle.standardError.write(Data("EdgeCompanion is not running (no recent heartbeat)\n".utf8))
      return 3
    }
    AwayFiles.ensureDirectory()
    let id = UUID().uuidString
    AwayFiles.writeAtomically(AwayMessage.request(command, id: id), to: AwayFiles.request)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if let text = AwayFiles.read(AwayFiles.response), let answer = AwayMessage.parseResponse(text, id: id) {
        print(answer.detail.isEmpty ? answer.outcome.rawValue : "\(answer.outcome.rawValue): \(answer.detail)")
        return answer.outcome.exitStatus
      }
      usleep(100_000)
    }
    FileHandle.standardError.write(Data("EdgeCompanion did not answer the \(command.rawValue) request\n".utf8))
    return 4
  }

  private static func status() -> Int32 {
    let beat = AwayFiles.age(of: AwayFiles.heartbeat).map { String(format: "%.0fs ago", $0) } ?? "never"
    print("heartbeat: \(beat)")
    if let line = AwayFiles.read(AwayFiles.heartbeat), !line.isEmpty { print(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if let state = AwayFiles.read(AwayFiles.state) { print("state: \(state)") }
    return 0
  }
}
