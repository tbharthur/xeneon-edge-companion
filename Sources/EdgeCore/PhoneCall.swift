import Foundation

/// A button one of the call windows offers, as Accessibility describes it.
public struct CallControl: Equatable, Sendable {
  /// The button's spoken label (its description, else its title).
  public var label: String
  /// Which on-screen window it sits in, so Answer and Decline are paired within one alert.
  public var window: Int

  public init(label: String, window: Int) {
    self.label = label
    self.window = window
  }
}

public enum PhoneCallState: Equatable, Sendable {
  case idle
  /// An incoming call alert is on screen.
  case ringing
  /// A call is connected (its in-call controls are on screen).
  case active
}

/// What the widget may do: the controls to press are indexes into the scanned list. A control is
/// only offered when exactly one matching button is on screen, so a tap never presses a guess.
public struct CallMatch: Equatable, Sendable {
  public var state: PhoneCallState
  /// The incoming call's Answer button (ringing only).
  public var answer: Int?
  /// Decline while ringing, End during a call.
  public var hangUp: Int?

  public init(state: PhoneCallState, answer: Int? = nil, hangUp: Int? = nil) {
    self.state = state
    self.answer = answer
    self.hangUp = hangUp
  }

  public static let idle = CallMatch(state: .idle)
}

/// The words the Phone app's call controls use, in the languages the Mac shows.
public struct CallLabels: Equatable, Sendable {
  public var answer: Set<String>
  public var decline: Set<String>
  public var end: Set<String>

  public init(answer: Set<String>, decline: Set<String>, end: Set<String>) {
    self.answer = Set(answer.map(Self.normalize))
    self.decline = Set(decline.map(Self.normalize))
    self.end = Set(end.map(Self.normalize))
  }

  /// English and Korean as shipped in macOS 26/27's FaceTimeNotificationUI and ConversationKit.
  /// "Accept" is deliberately absent: calendar invitations offer Accept and Decline too.
  public static let builtIn = CallLabels(
    answer: ["Answer", "응답"],
    decline: ["Decline", "거절"],
    end: ["End", "Hang Up", "종료", "통화 연결 중단"]
  )

  public func union(_ other: CallLabels) -> CallLabels {
    CallLabels(answer: answer.union(other.answer), decline: decline.union(other.decline), end: end.union(other.end))
  }

  /// Case- and spacing-insensitive, so "Hang up" and "Hang Up" compare equal.
  public static func normalize(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// Values for `keys` from a `.loctable` (locale → key → string) in the given languages, best
  /// match first: "en-GB" tries en_GB, then en.
  public static func strings(in table: [String: [String: String]], keys: [String], languages: [String]) -> Set<String> {
    var locales: [String] = []
    for lang in languages {
      let id = lang.replacingOccurrences(of: "-", with: "_")
      let parts = id.split(separator: "_").map(String.init)
      // "zh_Hans_CN" → zh_Hans_CN, zh_Hans, zh
      for n in stride(from: parts.count, through: 1, by: -1) {
        let candidate = parts.prefix(n).joined(separator: "_")
        if table[candidate] != nil, !locales.contains(candidate) {
          locales.append(candidate)
          break
        }
      }
    }
    var found = Set<String>()
    for locale in locales {
      for key in keys {
        if let value = table[locale]?[key], !value.isEmpty { found.insert(value) }
      }
    }
    return found
  }
}

public enum PhoneCall {
  /// Reads the call state from the buttons on screen.
  ///
  /// Ringing: one window holds exactly one Answer and exactly one Decline (the incoming call
  /// alert). Active: otherwise, exactly one End/Hang Up button with no Answer beside it. Anything
  /// ambiguous offers nothing to press: two alerts ringing reads as idle, and two End buttons as a
  /// call that the widget cannot end.
  public static func match(_ controls: [CallControl], labels: CallLabels) -> CallMatch {
    var byWindow: [Int: [Int]] = [:]
    for (i, c) in controls.enumerated() { byWindow[c.window, default: []].append(i) }

    var ringing: [(answer: Int, decline: Int)] = []
    var ends: [Int] = []
    for window in byWindow.keys.sorted() {
      let indexes = byWindow[window] ?? []
      func find(_ set: Set<String>) -> [Int] { indexes.filter { set.contains(CallLabels.normalize(controls[$0].label)) } }
      let answers = find(labels.answer)
      let declines = find(labels.decline)
      if answers.count == 1, declines.count == 1 {
        ringing.append((answers[0], declines[0]))
      } else if answers.isEmpty {
        ends += find(labels.end)
      }
    }

    if ringing.count == 1 { return CallMatch(state: .ringing, answer: ringing[0].answer, hangUp: ringing[0].decline) }
    if ringing.count > 1 { return .idle }
    if ends.count == 1 { return CallMatch(state: .active, hangUp: ends[0]) }
    if ends.count > 1 { return CallMatch(state: .active) }
    return .idle
  }
}
