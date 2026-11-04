import EdgeCore
import SwiftUI

/// Every Claude and Codex account from the local usage feed, in three groups: Claude Ultra plans
/// as full-width rows, then the Team seats and the Codex accounts as grids of tiles. Each account
/// leads with its tightest window (the one that will stop it first), with its windows as bars;
/// blocked accounts turn red with the time they free up. An account with no 5-hour window (Claude
/// Ultra, Codex Pro) gets no 5h bar.
struct QuotaWidget: View {
  @ObservedObject private var service = QuotaFeedService.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let headerH: CGFloat = 30
        let gap: CGFloat = 8
        let groups = QuotaBucket.group(service.accounts)
        let plan = Self.plan(groups, in: CGSize(width: geo.size.width, height: geo.size.height - headerH - Self.sectionGap))
        VStack(alignment: .leading, spacing: Self.sectionGap) {
          header.frame(height: headerH)
          if groups.isEmpty {
            Text(emptyText).font(Theme.text(16, weight: .medium)).foregroundStyle(Theme.textTertiary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ForEach(groups, id: \.bucket) { group in
              VStack(alignment: .leading, spacing: Self.labelGap) {
                sectionLabel(group.bucket, group.accounts)
                if group.bucket == .ultra {
                  VStack(spacing: gap) {
                    ForEach(group.accounts) { account in
                      QuotaTile(account: account, now: service.now, style: .row)
                        .frame(width: geo.size.width, height: plan.rowHeight)
                    }
                  }
                } else {
                  let columns = Self.columns(group.accounts.count, width: geo.size.width, gap: gap)
                  let tileW = floor((geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
                  LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileW), spacing: gap), count: columns), alignment: .leading, spacing: gap) {
                    ForEach(group.accounts) { account in
                      QuotaTile(account: account, now: service.now, style: .tile)
                        .frame(width: tileW, height: plan.tileHeight)
                    }
                  }
                }
              }
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .onAppear { service.retain() }
    .onDisappear { service.release() }
  }

  private static let sectionGap: CGFloat = 12
  private static let labelGap: CGFloat = 6
  private static let labelHeight: CGFloat = 15

  /// Tiles per row in a grid group: as many as fit at a comfortable width, never more than it has.
  static func columns(_ count: Int, width: CGFloat, gap: CGFloat) -> Int {
    max(1, min(count, Int((width + gap) / (104 + gap))))
  }

  /// Shares the height between the groups: an Ultra row counts as 0.62 of a tile row.
  static func plan(_ groups: [(bucket: QuotaBucket, accounts: [QuotaAccountView])], in size: CGSize, gap: CGFloat = 8)
    -> (rowHeight: CGFloat, tileHeight: CGFloat) {
    var weight: CGFloat = 0
    var fixed: CGFloat = 0
    for (index, group) in groups.enumerated() {
      let lines = group.bucket == .ultra
        ? group.accounts.count
        : Int(ceil(Double(group.accounts.count) / Double(columns(group.accounts.count, width: size.width, gap: gap))))
      weight += CGFloat(lines) * (group.bucket == .ultra ? 0.62 : 1)
      fixed += labelHeight + labelGap + gap * CGFloat(max(lines - 1, 0)) + (index > 0 ? sectionGap : 0)
    }
    guard weight > 0 else { return (70, 120) }
    let unit = max((size.height - fixed) / weight, 60)
    return (floor(min(unit * 0.62, 88)), floor(min(unit, 150)))
  }

  private func sectionLabel(_ bucket: QuotaBucket, _ accounts: [QuotaAccountView]) -> some View {
    let ready = accounts.filter { $0.group == .usable }.count
    let blocked = accounts.filter { $0.group == .blocked }.count
    let title: String = switch bucket {
    case .ultra: "Claude Ultra"
    case .team: accounts.allSatisfy { $0.plan?.localizedCaseInsensitiveContains("team") == true } ? "Claude Team" : "Claude"
    case .codex: "Codex"
    }
    let tint = bucket == .codex ? AIService.codex.tint : AIService.claude.tint
    return HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 10, height: 3)
      Text(title.uppercased()).font(Theme.text(11.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
      Spacer(minLength: 4)
      if blocked > 0 {
        Text(tr("\(blocked) 막힘", "\(blocked) blocked")).font(Theme.text(11.5, weight: .semibold)).foregroundStyle(Theme.critical)
      }
      Text(tr("\(ready)/\(accounts.count) 사용 가능", "\(ready)/\(accounts.count) ready")).font(Theme.text(11.5, weight: .semibold))
        .foregroundStyle(ready > 0 ? Theme.battery : Theme.textTertiary)
    }
    .lineLimit(1)
    .frame(height: Self.labelHeight)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(tr("AI 계정", "AI accounts")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 4)
      if case .unreachable = service.status {
        Pill(text: tr("피드 연결 안 됨", "Feed offline"), color: Theme.warning)
      }
    }
  }

  private var emptyText: String {
    switch service.status {
    case .waiting: return tr("확인 중…", "Checking…")
    case let .unreachable(message): return message
    case .ok: return tr("계정이 없어요", "No accounts in the feed")
    }
  }
}

struct Pill: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(color)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(Capsule().fill(color.opacity(0.14)))
  }
}

private struct QuotaTile: View {
  let account: QuotaAccountView
  let now: Date
  enum Style { case row, tile }
  /// `.row`: a full-width line with the number on the left and labeled bars on the right.
  var style: Style = .tile

  private var tint: Color { account.provider == .claude ? AIService.claude.tint : AIService.codex.tint }
  private var trusted: Bool { account.condition == .confirmed }

  var body: some View {
    if style == .row { rowBody } else { compactBody }
  }

  private var rowBody: some View {
    let lead = leadWindow
    return HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Circle().fill(tint).frame(width: 7, height: 7)
          Text(account.label).font(Theme.text(15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.6).allowsTightening(true)
          if account.active {
            Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
          }
        }
        if let blocked = blockedText {
          Text(blocked.title).font(Theme.text(17, weight: .bold)).foregroundStyle(blocked.color).lineLimit(1).minimumScaleFactor(0.7)
          Text(blocked.until).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
        } else if trusted {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(lead.map { "\(Int(($0.window.usedPct ?? 0).rounded()))" } ?? "0")
              .font(Theme.number(28, weight: .bold))
            Text("%").font(Theme.number(14, weight: .semibold)).opacity(0.7)
          }
          .foregroundStyle(QuotaTile.level(lead?.window.usedPct, tint))
        } else {
          Text(statusText).font(Theme.text(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(2).minimumScaleFactor(0.7)
        }
      }
      .frame(width: 104, alignment: .leading)
      // One labeled bar per window, with its percentage.
      VStack(spacing: 7) {
        ForEach(bars, id: \.0) { label, window in
          let isLead = lead?.label == label
          HStack(spacing: 6) {
            Text(label).font(Theme.text(11, weight: isLead ? .bold : .medium))
              .foregroundStyle(isLead ? Theme.textSecondary : Theme.textTertiary)
              .frame(width: 32, alignment: .leading)
            GeometryReader { g in
              ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                  .fill(trusted ? QuotaTile.level(window?.usedPct, tint) : Theme.textTertiary)
                  .frame(width: max(4, g.size.width * (window?.usedPct ?? 0) / 100))
                  .opacity(window?.usedPct ?? 0 > 0.5 ? 1 : 0)
              }
            }
            .frame(height: 6)
            Text(window?.usedPct.map { "\(Int($0.rounded()))%" } ?? "–")
              .font(Theme.number(11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
              .lineLimit(1).fixedSize()
              .frame(width: 34, alignment: .trailing)
          }
          .opacity(window == nil ? 0.4 : 1)
        }
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .frame(maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(prominentBackground))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(account.active ? 0.7 : 0.3), lineWidth: account.active ? 1.5 : 1))
  }

  private var prominentBackground: Color {
    if account.overallBlocked { return Theme.critical.opacity(0.18) }
    if account.fableBlocked { return Theme.warning.opacity(0.14) }
    return tint.opacity(0.08)
  }

  private var compactBody: some View {
    let lead = leadWindow
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Circle().fill(tint).frame(width: 7, height: 7)
        Text(account.label).font(Theme.text(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.6).allowsTightening(true).layoutPriority(1)
        Spacer(minLength: 0)
        if account.active {
          Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
        }
      }
      Spacer(minLength: 2)
      if let blocked = blockedText {
        Text(blocked.title).font(Theme.text(15, weight: .bold)).foregroundStyle(blocked.color).lineLimit(1).minimumScaleFactor(0.7)
        Text(blocked.until).font(Theme.text(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
      } else if trusted {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text(lead.map { "\(Int(($0.window.usedPct ?? 0).rounded()))" } ?? "0")
            .font(Theme.number(28, weight: .bold))
          Text("%").font(Theme.number(14, weight: .semibold)).opacity(0.7)
        }
        .foregroundStyle(QuotaTile.level(lead?.window.usedPct, tint))
      } else {
        Text(statusText).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(2).minimumScaleFactor(0.7)
      }
      Spacer(minLength: 4)
      // The windows as small columns; the tallest is the number above.
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(bars, id: \.0) { label, window in
          let isLead = lead?.label == label
          VStack(spacing: 3) {
            GeometryReader { g in
              ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.track)
                RoundedRectangle(cornerRadius: 3)
                  .fill(trusted ? QuotaTile.level(window?.usedPct, tint) : Theme.textTertiary)
                  .frame(height: max(3, g.size.height * (window?.usedPct ?? 0) / 100))
                  .opacity(window?.usedPct ?? 0 > 0.5 ? 1 : 0)
              }
            }
            .opacity(window == nil ? 0.3 : 1)
            Text(label).font(Theme.text(10, weight: isLead ? .bold : .medium))
              .foregroundStyle(isLead ? Theme.textSecondary : Theme.textTertiary).lineLimit(1).fixedSize()
          }
        }
      }
      .frame(height: 40)
    }
    .padding(.vertical, 10).padding(.horizontal, 9)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(account.active ? tint.opacity(0.6) : Color.white.opacity(0.05), lineWidth: 1))
  }

  private var background: Color {
    if account.overallBlocked { return Theme.critical.opacity(0.16) }
    if account.fableBlocked { return Theme.warning.opacity(0.12) }
    return Color.white.opacity(0.04)
  }

  /// The window that will stop this account first.
  private var leadWindow: (label: String, window: QuotaWindowView)? {
    bars.compactMap { label, w in w.map { (label, $0) } }.max { ($0.1.usedPct ?? 0) < ($1.1.usedPct ?? 0) }
  }

  private var bars: [(String, QuotaWindowView?)] {
    var list: [(String, QuotaWindowView?)] = []
    if account.fiveHour != nil { list.append(("5h", account.fiveHour)) }
    list.append((tr("주간", "Wk"), account.weekly))
    if account.provider == .claude { list.append(("Fable", account.fable)) }
    return list
  }

  private var blockedText: (title: String, until: String, color: Color)? {
    guard trusted else { return nil }
    if account.overallBlocked {
      return (tr("막힘", "Blocked"), account.overallFreeAt.map { tr("\(QuotaTile.clock($0, now: now))까지", "until \(QuotaTile.clock($0, now: now))") } ?? "", Theme.critical)
    }
    if account.fableBlocked {
      return (tr("Fable 막힘", "Fable blocked"), account.fableFreeAt.map { tr("\(QuotaTile.clock($0, now: now))까지", "until \(QuotaTile.clock($0, now: now))") } ?? "", Theme.warning)
    }
    return nil
  }

  private var statusText: String {
    switch account.condition {
    case .disabled: return tr("꺼짐", "Disabled")
    case .signedOut: return tr("로그아웃됨", "Signed out")
    case .unconfirmed: return tr("확인 실패 · 마지막 값", "Last good reading")
    case .unknown: return account.state == "error" ? tr("확인 실패", "Couldn't check") : tr("데이터 없음", "No data yet")
    case .confirmed: return ""
    }
  }

  static func level(_ used: Double?, _ tint: Color) -> Color {
    guard let used else { return tint }
    return used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : tint
  }

  /// Today: "4:20 PM"; within six days: "Fri 4 PM" or "Tue 12:20 AM"; later: "Nov 3".
  static func clock(_ date: Date, now: Date) -> String {
    let f = DateFormatter()
    if Calendar.current.isDate(date, inSameDayAs: now) {
      f.setLocalizedDateFormatFromTemplate("jmm")
    } else if date.timeIntervalSince(now) < 6 * 86400 {
      f.setLocalizedDateFormatFromTemplate(Calendar.current.component(.minute, from: date) == 0 ? "EEEj" : "EEEjmm")
    } else {
      f.setLocalizedDateFormatFromTemplate("MMMd")
    }
    return f.string(from: date)
  }
}
