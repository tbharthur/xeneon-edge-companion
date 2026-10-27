import Foundation

/// A local multi-account usage feed (contract v1): every Claude and Codex account with its
/// rate-limit windows. Classification follows the same rules as the feed's other front ends, so
/// an account reads "usable" or "blocked" identically everywhere.
public struct QuotaFeed: Decodable, Equatable, Sendable {
  public var refreshIntervalSeconds: Double?
  public var accounts: [Account]

  public struct Account: Decodable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var label: String?
    public var plan: String?
    public var state: String?
    public var active: Bool?
    public var disabled: Bool?
    public var detail: String?
    public var measuredAt: String?
    public var windows: [Window]?
  }

  public struct Window: Decodable, Equatable, Sendable {
    public var key: String
    public var label: String?
    public var usedPct: Double?
    public var resetsAt: String?
  }

  public static func decode(_ data: Data) throws -> QuotaFeed {
    try JSONDecoder().decode(QuotaFeed.self, from: data)
  }
}

public enum QuotaProvider: Int, Sendable { case claude, codex }

/// How far an account's numbers can be trusted right now.
public enum QuotaCondition: Sendable { case confirmed, unconfirmed, unknown, signedOut, disabled }

public enum QuotaGroup: Int, Sendable { case usable, blocked, unknown }

public struct QuotaWindowView: Equatable, Sendable {
  public var key: String
  /// Nil once the window has reset (the old reading no longer applies).
  public var usedPct: Double?
  public var resetsAt: Date?
  public var exhausted: Bool { (usedPct ?? 0) >= QuotaModel.exhaustedPct }
}

public struct QuotaAccountView: Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: QuotaProvider
  public var label: String
  public var plan: String?
  public var active: Bool
  public var detail: String?
  public var state: String
  public var condition: QuotaCondition
  public var group: QuotaGroup
  public var measuredAt: Date?
  public var fiveHour: QuotaWindowView?
  public var weekly: QuotaWindowView?
  /// Claude's Fable-only weekly window.
  public var fable: QuotaWindowView?
  public var overallBlocked: Bool
  /// When every blocking window has reset; nil if unknown.
  public var overallFreeAt: Date?
  public var fableBlocked: Bool
  public var fableFreeAt: Date?

  /// The fullest window, for ordering usable accounts by headroom.
  var headroomScore: Double {
    [fiveHour, weekly, fable].compactMap { $0?.usedPct }.max() ?? 0
  }

  var fableUsable: Bool { group == .usable && provider == .claude && !fableBlocked && fable != nil }
}

public enum QuotaModel {
  public static let exhaustedPct = 99.5
  /// A reading older than this many refresh intervals is shown but not trusted.
  public static let staleIntervals = 3.0

  public static func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let plain = ISO8601DateFormatter()
    if let d = plain.date(from: s) { return d }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: s)
  }

  /// Accounts in display order: Claude then Codex; within each, usable (most headroom and Fable
  /// first), then blocked (soonest free first), then unknown.
  public static func accounts(from feed: QuotaFeed, feedReachable: Bool, now: Date) -> [QuotaAccountView] {
    let staleAfter = (feed.refreshIntervalSeconds ?? 900) * staleIntervals
    return feed.accounts.map { view($0, feedReachable: feedReachable, staleAfter: staleAfter, now: now) }.sorted(by: order)
  }

  static func view(_ raw: QuotaFeed.Account, feedReachable: Bool, staleAfter: TimeInterval, now: Date) -> QuotaAccountView {
    let provider: QuotaProvider = raw.provider == "codex" ? .codex : .claude
    var byKey: [String: QuotaWindowView] = [:]
    for w in raw.windows ?? [] {
      let resets = parseDate(w.resetsAt)
      let passed = resets.map { $0 <= now } ?? false
      let pct = w.usedPct.map { min(max($0, 0), 100) }
      byKey[w.key] = QuotaWindowView(key: w.key, usedPct: passed ? nil : pct, resetsAt: passed ? nil : resets)
    }
    let measured = parseDate(raw.measuredAt)
    let hasReading = !(raw.windows ?? []).isEmpty && measured != nil
    let age = measured.map { now.timeIntervalSince($0) } ?? .infinity

    let condition: QuotaCondition
    if raw.disabled == true { condition = .disabled }
    else if raw.state == "signed_out" { condition = .signedOut }
    else if !feedReachable { condition = hasReading ? .unconfirmed : .unknown }
    else if raw.state == "ok", hasReading { condition = age > staleAfter ? .unconfirmed : .confirmed }
    else if raw.state == "ok" { condition = .confirmed }
    else if raw.state == "error" { condition = hasReading ? .unconfirmed : .unknown }
    else { condition = .unknown }

    let fiveHour = byKey["five_hour"]
    let weekly = byKey["weekly"]
    let fable = provider == .claude ? byKey["weekly_fable"] : nil
    let overall = [fiveHour, weekly].compactMap { $0 }
    let overallBlocked = overall.contains { $0.exhausted }
    let fableBlocked = overallBlocked || (fable?.exhausted ?? false)
    let confirmed = condition == .confirmed
    let group: QuotaGroup = confirmed ? (overallBlocked ? .blocked : .usable) : .unknown

    return QuotaAccountView(
      id: raw.id, provider: provider, label: raw.label ?? raw.id, plan: raw.plan, active: raw.active == true,
      detail: raw.detail, state: raw.state ?? "unknown", condition: condition, group: group, measuredAt: measured,
      fiveHour: fiveHour, weekly: weekly, fable: fable,
      overallBlocked: confirmed && overallBlocked,
      overallFreeAt: confirmed && overallBlocked ? freeAt(overall) : nil,
      fableBlocked: confirmed && provider == .claude && fableBlocked,
      fableFreeAt: confirmed && provider == .claude && fableBlocked ? freeAt(overall + [fable].compactMap { $0 }) : nil)
  }

  /// When every exhausted window has reset; nil if any of them has no reset time.
  static func freeAt(_ windows: [QuotaWindowView]) -> Date? {
    let blocking = windows.filter(\.exhausted)
    guard !blocking.isEmpty else { return nil }
    let times = blocking.compactMap(\.resetsAt)
    return times.count == blocking.count ? times.max() : nil
  }

  static func order(_ a: QuotaAccountView, _ b: QuotaAccountView) -> Bool {
    if a.provider != b.provider { return a.provider.rawValue < b.provider.rawValue }
    if a.group != b.group { return a.group.rawValue < b.group.rawValue }
    if a.group == .usable {
      if a.fableUsable != b.fableUsable { return a.fableUsable }
      if a.headroomScore != b.headroomScore { return a.headroomScore < b.headroomScore }
    }
    if a.group == .blocked {
      let am = a.overallFreeAt ?? .distantFuture
      let bm = b.overallFreeAt ?? .distantFuture
      if am != bm { return am < bm }
    }
    return a.label.localizedStandardCompare(b.label) == .orderedAscending
  }
}
