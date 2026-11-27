import Foundation

// Pure rules for "Arthur is away / back": which input is a person, whether a blank request is
// honoured, which brightness to restore, and the small file protocol the `--away` command uses.

/// `eventSourceUserData` values this app puts on the events it posts.
public enum InputTag {
  /// "EDGE": touches on the Edge, replayed as mouse events. A person made these.
  public static let touch: Int64 = 0x4544_4745
  /// "EDGD": the Dock relocator's pointer pushes. Automation, never a person.
  public static let dock: Int64 = 0x4544_4744
}

/// Decides whether an input event came from a person at the desk.
///
/// Hardware events carry source process id 0. Anything another process posts carries that
/// process's id: Computer Use, the Dock relocator, any automation. Two posters stand in for the
/// person and count: this app's own Edge touch replays (tagged `InputTag.touch`), and the
/// processes in `personProxies`, which re-post the person's own mouse buttons and scrolls.
public enum HumanInput {
  public enum Verdict: Equatable, Sendable {
    /// A person; the string names the input for the log ("mouse move", "key").
    case person(String)
    /// Posted by software on its own.
    case synthetic
  }

  /// Processes that re-post the person's own input (Logitech Options+ rewrites real scrolls and
  /// button presses).
  public static let personProxies: Set<String> = ["logioptionsplus_agent"]

  /// CGEventType raw values a person makes, with a name for the log. Leaves out mouse
  /// entered/exited (8, 9) and system-defined (14), which a display waking up posts on its own.
  public static let personTypes: [UInt32: String] = [
    1: "click", 2: "click", 3: "right click", 4: "right click", 5: "mouse move",
    6: "drag", 7: "drag", 10: "key", 11: "key", 12: "modifier key",
    18: "gesture", 19: "gesture", 20: "gesture",
    22: "scroll", 23: "tablet", 24: "tablet",
    25: "mouse button", 26: "mouse button", 27: "drag",
    29: "gesture", 30: "gesture", 31: "gesture", 32: "gesture",
  ]

  /// The event mask covering `personTypes`.
  public static var personMask: UInt64 {
    personTypes.keys.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64($1)) }
  }

  static let mouseMoved: UInt32 = 5

  /// Returns nil for event types a person does not make (nothing to decide).
  /// - Parameters:
  ///   - sourcePID: `eventSourceUnixProcessID`; 0 for hardware.
  ///   - userData: `eventSourceUserData`.
  ///   - ownPID: this app's process id.
  ///   - moved: false for a pointer move with no delta (the window server repositioning the
  ///     cursor, as around a display reconfiguration), which is not a hand on the mouse.
  ///   - processName: looks up a poster's process name; called only for posted events.
  public static func classify(type: UInt32, sourcePID: Int64, userData: Int64, ownPID: Int32,
                              moved: Bool = true, processName: (Int32) -> String?) -> Verdict? {
    guard let kind = personTypes[type] else { return nil }
    if sourcePID == 0 {
      if type == mouseMoved, !moved { return nil }
      return .person(kind)
    }
    guard let pid = Int32(exactly: sourcePID) else { return .synthetic }
    if pid == ownPID {
      return userData == InputTag.touch ? .person("Edge touch") : .synthetic
    }
    if let name = processName(pid), personProxies.contains(name) {
      return .person("\(kind) via \(name)")
    }
    return .synthetic
  }
}

/// What a blank request does.
public enum AwayRequest {
  public enum Outcome: String, Sendable, CaseIterable {
    case blanked
    case alreadyAway = "already-away"
    /// A person used the Mac too recently; Home Assistant's view of the room can lag.
    case ignoredActive = "ignored-active"
    /// Without the input watch nothing could wake the screens again, so never go dark.
    case unavailable
    case restored
    case notAway = "not-away"

    /// The `--away` command's exit status: 0 when the request was handled as designed.
    public var exitStatus: Int32 { self == .unavailable ? 5 : 0 }
  }

  public static let minimumIdle: TimeInterval = 60

  public static func decideBlank(isAway: Bool, inputWatchRunning: Bool, secondsSinceInput: TimeInterval,
                                 minimumIdle: TimeInterval = minimumIdle) -> Outcome {
    if isAway { return .alreadyAway }
    if !inputWatchRunning { return .unavailable }
    if secondsSinceInput < minimumIdle { return .ignoredActive }
    return .blanked
  }
}

/// Request and response lines exchanged through files with the `--away` command.
public enum AwayMessage {
  public enum Command: String, Sendable { case blank, unblank }

  public static func request(_ command: Command, id: String) -> String { "\(command.rawValue) \(id)" }

  public static func parseRequest(_ text: String) -> (command: Command, id: String)? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard parts.count == 2, let command = Command(rawValue: String(parts[0])), !parts[1].isEmpty else { return nil }
    return (command, String(parts[1]))
  }

  public static func response(id: String, outcome: AwayRequest.Outcome, detail: String = "") -> String {
    detail.isEmpty ? "\(id) \(outcome.rawValue)" : "\(id) \(outcome.rawValue) \(detail)"
  }

  /// The outcome and detail if `text` answers request `id`.
  public static func parseResponse(_ text: String, id: String) -> (outcome: AwayRequest.Outcome, detail: String)? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, parts[0] == id, let outcome = AwayRequest.Outcome(rawValue: String(parts[1])) else { return nil }
    return (outcome, parts.count > 2 ? String(parts[2]) : "")
  }

  /// The command treats the app as gone when its heartbeat is older than this.
  public static let heartbeatStaleAfter: TimeInterval = 20
}

/// DDC brightness bookkeeping, so a monitor is never restored to a dark level.
public enum AwayBrightness {
  /// MCCS luminance.
  public static let vcp: UInt8 = 0x10
  /// Readings below this are left over from blanking, not a choice.
  public static let minimumOrdinary = 10
  public static let fallback = 100

  /// The level to restore after dimming a monitor that read `current` (nil: no reading), and the
  /// ordinary level to remember. Nil `restoreTo` means "don't dim": nothing safe to come back to.
  public static func plan(current: Int?, lastGood: Int?) -> (restoreTo: Int?, lastGood: Int?) {
    if let current, current >= minimumOrdinary { return (current, current) }
    if current != nil { return (lastGood ?? fallback, lastGood) }
    return (lastGood, lastGood)
  }
}

/// What survives a restart: whether the screens were dark and what to bring each monitor back to.
public struct AwayState: Codable, Equatable, Sendable {
  public var blanked = false
  /// Display UUID -> DDC brightness to restore.
  public var savedLuminance: [String: Int] = [:]
  /// Display UUID -> last ordinary brightness seen, kept across episodes.
  public var lastGood: [String: Int] = [:]

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    blanked = try c.decodeIfPresent(Bool.self, forKey: .blanked) ?? false
    savedLuminance = try c.decodeIfPresent([String: Int].self, forKey: .savedLuminance) ?? [:]
    lastGood = try c.decodeIfPresent([String: Int].self, forKey: .lastGood) ?? [:]
  }

  /// Something is still dark from an earlier run.
  public var needsRestore: Bool { blanked || !savedLuminance.isEmpty }
}
