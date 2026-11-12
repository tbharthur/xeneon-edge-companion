import EdgeCore
import SwiftUI

/// Every Claude and Codex account from the local usage feed, one row each, under small Claude
/// Ultra / Claude Team / Codex labels. A row says three things: the account's email, whether it
/// can be used, and, when it is blocked, when it comes back. Usage percentages stay secondary.
struct QuotaWidget: View {
  @ObservedObject private var service = QuotaFeedService.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let groups = QuotaBucket.group(service.accounts)
        // Wide enough for the email and its status on one line; otherwise the status goes under it.
        let oneLine = geo.size.width >= 420
        let rowH = Self.rowHeight(groups, height: geo.size.height, oneLine: oneLine)
        VStack(alignment: .leading, spacing: Self.sectionGap) {
          header.frame(height: Self.headerHeight)
          if groups.isEmpty {
            Text(emptyText).font(Theme.text(16, weight: .medium)).foregroundStyle(Theme.textTertiary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ForEach(groups, id: \.bucket) { group in
              VStack(alignment: .leading, spacing: Self.rowGap) {
                sectionLabel(group.bucket, group.accounts).frame(height: Self.labelHeight)
                ForEach(group.accounts) { account in
                  QuotaRow(account: account, now: service.now, oneLine: oneLine)
                    .frame(width: geo.size.width, height: rowH)
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

  private static let headerHeight: CGFloat = 24
  private static let sectionGap: CGFloat = 10
  private static let rowGap: CGFloat = 5
  private static let labelHeight: CGFloat = 14

  /// Rows share the height left after the header and group labels, within readable limits.
  static func rowHeight(_ groups: [(bucket: QuotaBucket, accounts: [QuotaAccountView])], height: CGFloat, oneLine: Bool) -> CGFloat {
    let rows = groups.reduce(0) { $0 + $1.accounts.count }
    guard rows > 0 else { return 44 }
    let fixed = headerHeight + CGFloat(groups.count) * (sectionGap + labelHeight) + CGFloat(rows) * rowGap
    let share = floor((height - fixed) / CGFloat(rows))
    return min(max(share, oneLine ? 30 : 40), oneLine ? 48 : 58)
  }

  private func sectionLabel(_ bucket: QuotaBucket, _ accounts: [QuotaAccountView]) -> some View {
    let title: String = switch bucket {
    case .ultra: "Claude Ultra"
    case .team: accounts.allSatisfy { $0.plan?.localizedCaseInsensitiveContains("team") == true } ? "Claude Team" : "Claude"
    case .codex: "Codex"
    }
    return Text(title.uppercased()).font(Theme.text(11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
      .lineLimit(1)
  }

  private var header: some View {
    let ready = service.accounts.filter { $0.group == .usable }.count
    return HStack(spacing: 8) {
      Text(tr("AI 계정", "AI accounts")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
      Spacer(minLength: 4)
      if case .unreachable = service.status {
        Pill(text: tr("피드 연결 안 됨", "Feed offline"), color: Theme.warning)
      } else if !service.accounts.isEmpty {
        Text(tr("\(service.accounts.count)개 중 \(ready)개 사용 가능", "\(ready) of \(service.accounts.count) ready"))
          .font(Theme.text(13, weight: .semibold))
          .foregroundStyle(ready > 0 ? Theme.battery : Theme.critical)
          .lineLimit(1)
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

/// One account: a status dot, the email and its status, and for a blocked account the time it
/// comes back, right-aligned in the same date-over-time format on every row.
private struct QuotaRow: View {
  let account: QuotaAccountView
  let now: Date
  /// Email and status side by side; otherwise the status sits under the email.
  let oneLine: Bool

  var body: some View {
    let headline = account.headline
    HStack(spacing: 10) {
      Circle().fill(color(headline)).frame(width: 9, height: 9)
      if oneLine {
        email
        Spacer(minLength: 8)
        status(headline)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          email
          status(headline)
        }
        Spacer(minLength: 6)
      }
      if let until = returnTime(headline) {
        backAt(until, tint: color(headline)).layoutPriority(1)
      }
    }
    .padding(.horizontal, 12)
    .frame(maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background(headline)))
  }

  private var email: some View {
    Text(account.displayName)
      .font(Theme.text(15, weight: .semibold))
      .foregroundStyle(Theme.textPrimary)
      .lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true).truncationMode(.middle)
  }

  @ViewBuilder
  private func status(_ headline: QuotaHeadline) -> some View {
    switch headline {
    case let .ready(used):
      HStack(spacing: 6) {
        Text(tr("사용 가능", "Ready")).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.battery)
        if let used {
          Text(tr("\(Int(used.rounded()))% 사용", "\(Int(used.rounded()))% used"))
            .font(Theme.text(12.5, weight: .medium))
            .foregroundStyle(used >= 75 ? Theme.warning : Theme.textTertiary)
        }
      }
      .lineLimit(1)
    case .blocked:
      Text(tr("막힘", "Blocked")).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.critical).lineLimit(1)
    case .fableBlocked:
      Text(tr("Fable 막힘", "Fable blocked")).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.warning).lineLimit(1)
    case .unavailable:
      Text(unavailableText).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }
  }

  private func returnTime(_ headline: QuotaHeadline) -> Date? {
    switch headline {
    case let .blocked(until), let .fableBlocked(until): return until
    default: return nil
    }
  }

  /// A small tinted "12:00 PM" over a bold white "Fri, 11/13", right-aligned with fixed-width
  /// digits so the rows line up.
  private func backAt(_ until: Date, tint: Color) -> some View {
    let (day, time) = Self.backTime(until)
    return VStack(alignment: .trailing, spacing: 1) {
      Text(time).font(Theme.number(12, weight: .semibold)).foregroundStyle(tint)
      Text(day).font(Theme.number(15, weight: .bold)).foregroundStyle(Theme.textPrimary)
    }
    .lineLimit(1).fixedSize()
  }

  /// Date and time the account comes back, rounded to the nearest minute so a reset at 6:59:59
  /// reads 7:00 PM. Always the same shape: weekday and month/day, then the clock time.
  static func backTime(_ raw: Date) -> (day: String, time: String) {
    let date = Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    let day = DateFormatter()
    day.setLocalizedDateFormatFromTemplate("EEEMd")
    let time = DateFormatter()
    time.setLocalizedDateFormatFromTemplate("jmm")
    return (day.string(from: date), time.string(from: date))
  }

  private var unavailableText: String {
    switch account.condition {
    case .disabled: return tr("꺼짐", "Disabled")
    case .signedOut: return tr("로그아웃됨", "Signed out")
    case .unconfirmed: return tr("확인 안 됨", "Not confirmed")
    case .unknown: return account.state == "error" ? tr("확인 실패", "Couldn't check") : tr("데이터 없음", "No data yet")
    case .confirmed: return ""
    }
  }

  private func color(_ headline: QuotaHeadline) -> Color {
    switch headline {
    case .ready: return Theme.battery
    case .blocked: return Theme.critical
    case .fableBlocked: return Theme.warning
    case .unavailable: return Theme.textTertiary
    }
  }

  private func background(_ headline: QuotaHeadline) -> Color {
    switch headline {
    case .blocked: return Theme.critical.opacity(0.13)
    case .fableBlocked: return Theme.warning.opacity(0.10)
    default: return Color.white.opacity(0.04)
    }
  }
}
