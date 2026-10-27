import EdgeCore
import SwiftUI

/// Every Claude and Codex account from the local usage feed as a grid of tiles. Each tile leads
/// with the account's tightest window (the one that will stop it first), with the three windows
/// as bars underneath; blocked accounts turn red with the time they free up.
struct QuotaWidget: View {
  @ObservedObject private var service = QuotaFeedService.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let accounts = service.accounts
        let headerH: CGFloat = 30
        let gap: CGFloat = 8
        let grid = Self.grid(count: accounts.count, in: CGSize(width: geo.size.width, height: geo.size.height - headerH - gap), gap: gap)
        VStack(alignment: .leading, spacing: gap) {
          header.frame(height: headerH)
          if accounts.isEmpty {
            Text(emptyText).font(Theme.text(16, weight: .medium)).foregroundStyle(Theme.textTertiary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.tile.width), spacing: gap), count: grid.columns), alignment: .leading, spacing: gap) {
              ForEach(accounts) { account in
                QuotaTile(account: account, now: service.now)
                  .frame(width: grid.tile.width, height: grid.tile.height)
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

  /// The column count whose tiles come closest to a comfortable shape, filling the card.
  static func grid(count: Int, in size: CGSize, gap: CGFloat) -> (columns: Int, tile: CGSize) {
    guard count > 0, size.width > 0, size.height > 0 else { return (1, .zero) }
    var best: (columns: Int, tile: CGSize, score: CGFloat) = (1, .zero, .infinity)
    for columns in 1 ... count {
      let rows = Int(ceil(Double(count) / Double(columns)))
      let w = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
      let h = min((size.height - gap * CGFloat(rows - 1)) / CGFloat(rows), 190)
      guard w >= 88, h >= 96 else { continue }
      // Prefer tiles a little taller than wide, and fewer empty cells.
      let shape = abs(log(h / w) - log(1.25))
      let empty = CGFloat(rows * columns - count) * 0.15
      if shape + empty < best.score { best = (columns, CGSize(width: floor(w), height: floor(h)), shape + empty) }
    }
    if best.tile == .zero {
      // Too many for comfortable tiles: squeeze into the widest grid that fits.
      let columns = max(1, Int((size.width + gap) / (88 + gap)))
      let rows = Int(ceil(Double(count) / Double(columns)))
      return (columns, CGSize(width: floor((size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)),
                              height: floor((size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))))
    }
    return (best.columns, best.tile)
  }

  private var header: some View {
    let usable = service.accounts.filter { $0.group == .usable }.count
    let blocked = service.accounts.filter { $0.group == .blocked }.count
    return HStack(spacing: 8) {
      Text(tr("AI 계정", "AI accounts")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
      Spacer(minLength: 4)
      if case .unreachable = service.status {
        Pill(text: tr("피드 연결 안 됨", "Feed offline"), color: Theme.warning)
      } else if !service.accounts.isEmpty {
        Pill(text: tr("\(usable)개 사용 가능", "\(usable) ready"), color: Theme.battery)
        if blocked > 0 { Pill(text: tr("\(blocked)개 막힘", "\(blocked) blocked"), color: Theme.critical) }
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

  private var tint: Color { account.provider == .claude ? AIService.claude.tint : AIService.codex.tint }
  private var trusted: Bool { account.condition == .confirmed }

  var body: some View {
    let lead = leadWindow
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Circle().fill(tint).frame(width: 7, height: 7)
        Text(account.label).font(Theme.text(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.75)
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
      // The three windows as small columns; the tallest is the number above.
      HStack(alignment: .bottom, spacing: 6) {
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
            Text(label).font(Theme.text(10.5, weight: isLead ? .bold : .medium))
              .foregroundStyle(isLead ? Theme.textSecondary : Theme.textTertiary).lineLimit(1).fixedSize()
          }
        }
      }
      .frame(height: 40)
    }
    .padding(10)
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
    var list: [(String, QuotaWindowView?)] = [("5h", account.fiveHour), (tr("주간", "Wk"), account.weekly)]
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
