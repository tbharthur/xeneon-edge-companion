import EdgeCore
import SwiftUI

/// Every Claude and Codex account from the local usage feed: which can take work now, which are
/// blocked and until when, and each account's 5-hour, weekly and Fable windows.
/// Rows get a second line with bars when the card is tall enough.
struct QuotaWidget: View {
  @ObservedObject private var service = QuotaFeedService.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let accounts = service.accounts
        let providers = Set(accounts.map(\.provider)).count
        let headerH: CGFloat = 26
        let sectionH: CGFloat = providers > 1 ? 20 : 0
        let rowSpace = geo.size.height - headerH - sectionH * CGFloat(providers)
        let rowH = accounts.isEmpty ? 0 : rowSpace / CGFloat(accounts.count)
        let detailed = rowH >= 50
        let narrow = geo.size.width < 300
        VStack(alignment: .leading, spacing: 0) {
          header(compact: !detailed, narrow: narrow).frame(height: headerH, alignment: .top)
          if accounts.isEmpty {
            Text(emptyText).font(Theme.text(13)).foregroundStyle(Theme.textTertiary).frame(maxHeight: .infinity)
          }
          ForEach([QuotaProvider.claude, .codex], id: \.self) { provider in
            let rows = accounts.filter { $0.provider == provider }
            if !rows.isEmpty {
              if providers > 1 {
                Text(provider == .claude ? "Claude" : "Codex")
                  .font(Theme.text(11, weight: .bold)).foregroundStyle(tint(provider).opacity(0.85))
                  .frame(height: sectionH, alignment: .bottomLeading)
              }
              ForEach(rows) { account in
                QuotaRow(account: account, now: service.now, detailed: detailed, narrow: narrow, tint: tint(provider))
                  .frame(height: min(rowH, detailed ? 64 : 34))
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

  private func header(compact: Bool, narrow: Bool) -> some View {
    let usable = service.accounts.filter { $0.group == .usable }.count
    let blocked = service.accounts.filter { $0.group == .blocked }.count
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      if !narrow {
        Text(tr("계정 사용량", "Accounts")).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
      }
      if !service.accounts.isEmpty {
        Text(narrow ? "\(usable)✓" : tr("\(usable)개 사용 가능", "\(usable) usable")).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.battery)
        if blocked > 0 {
          Text(narrow ? "\(blocked)✕" : tr("\(blocked)개 막힘", "\(blocked) blocked")).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.critical)
        }
      }
      Spacer(minLength: 0)
      if case .unreachable = service.status {
        Text(tr("피드 연결 안 됨", "Feed offline")).font(Theme.text(11.5, weight: .medium)).foregroundStyle(Theme.warning)
      } else if compact, !service.accounts.isEmpty {
        // Column labels for the compact rows' percentages.
        ForEach(QuotaRow.columnLabels, id: \.self) { label in
          Text(label).font(Theme.text(10.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
            .frame(width: QuotaRow.column(narrow), alignment: .trailing)
        }
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

  private func tint(_ p: QuotaProvider) -> Color { p == .claude ? AIService.claude.tint : AIService.codex.tint }
}

private struct QuotaRow: View {
  let account: QuotaAccountView
  let now: Date
  let detailed: Bool
  let narrow: Bool
  let tint: Color

  var body: some View {
    if detailed {
      VStack(alignment: .leading, spacing: 6) {
        title
        HStack(spacing: 12) {
          ForEach(windows, id: \.0) { label, window in
            WindowBar(label: label, window: window, tint: tint, dimmed: account.condition != .confirmed)
          }
        }
      }
      .frame(maxHeight: .infinity, alignment: .center)
    } else {
      // Compact: the dot carries the status colour, so the name keeps the room.
      HStack(spacing: narrow ? 4 : 8) {
        Circle().fill(status.color).frame(width: 7, height: 7)
        Text(account.label).font(Theme.text(narrow ? 12.5 : 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).truncationMode(.tail).layoutPriority(1)
        Spacer(minLength: 0)
        ForEach(windows, id: \.0) { _, window in
          Text(percent(window)).font(Theme.number(narrow ? 11.5 : 13, weight: .semibold))
            .foregroundStyle(QuotaColors.color(window, tint, dimmed: account.condition != .confirmed))
            .frame(width: Self.column(narrow), alignment: .trailing)
        }
      }
      .frame(maxHeight: .infinity, alignment: .center)
    }
  }

  static func column(_ narrow: Bool) -> CGFloat { narrow ? 31 : 38 }
  static var columnLabels: [String] { [tr("5시간", "5h"), tr("주간", "Week"), "Fable"] }

  private var title: some View {
    HStack(spacing: 7) {
      Circle().fill(account.active ? tint : Color.clear)
        .overlay(Circle().strokeBorder(tint.opacity(account.active ? 0 : 0.35), lineWidth: 1))
        .frame(width: 7, height: 7)
      Text(account.label).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
      if detailed, let plan = account.plan {
        Text(plan.uppercased())
          .font(Theme.text(9.5, weight: .bold)).foregroundStyle(tint)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Capsule().fill(tint.opacity(0.16)))
          .lineLimit(1).fixedSize()
      }
      Spacer(minLength: 4)
      Text(status.text).font(Theme.text(detailed ? 12.5 : 11.5, weight: .medium)).foregroundStyle(status.color).lineLimit(1)
    }
  }

  /// Always the same three columns so rows line up; a window the plan doesn't have shows a dash.
  private var windows: [(String, QuotaWindowView?)] {
    let labels = Self.columnLabels
    return [(labels[0], account.fiveHour), (labels[1], account.weekly), (labels[2], account.provider == .claude ? account.fable : nil)]
  }

  private func percent(_ w: QuotaWindowView?) -> String {
    guard let w else { return "–" }
    return "\(Int((w.usedPct ?? 0).rounded()))%"
  }

  private var status: (text: String, color: Color) {
    switch account.condition {
    case .disabled: return (tr("꺼짐", "Disabled"), Theme.textTertiary)
    case .signedOut: return (tr("로그아웃됨", "Signed out"), Theme.textTertiary)
    case .unknown: return (account.state == "error" ? tr("확인 실패", "Couldn't check") : (account.detail ?? tr("데이터 없음", "No data yet")), Theme.textTertiary)
    case .unconfirmed: return (tr("확인 실패 · 마지막 값", "Couldn't check · last good"), Theme.textTertiary)
    case .confirmed: break
    }
    if account.overallBlocked {
      return (account.overallFreeAt.map { tr("\(QuotaColors.clock($0, now: now))까지 막힘", "Blocked until \(QuotaColors.clock($0, now: now))") } ?? tr("막힘", "Blocked"), Theme.critical)
    }
    if account.fableBlocked {
      return (account.fableFreeAt.map { tr("Fable \(QuotaColors.clock($0, now: now))까지 막힘", "Fable blocked until \(QuotaColors.clock($0, now: now))") } ?? tr("Fable 막힘", "Fable blocked"), Theme.warning)
    }
    return (tr("사용 가능", "Usable"), Theme.battery)
  }
}

private struct WindowBar: View {
  let label: String
  let window: QuotaWindowView?
  let tint: Color
  let dimmed: Bool

  var body: some View {
    let color = QuotaColors.color(window, tint, dimmed: dimmed)
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(label).font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
        Spacer(minLength: 2)
        Text(window.map { "\(Int(($0.usedPct ?? 0).rounded()))%" } ?? "–").font(Theme.number(12.5, weight: .semibold)).foregroundStyle(color)
      }
      UsageBar(value: (window?.usedPct ?? 0) / 100, tint: color, height: 5)
        .opacity(window == nil ? 0.4 : 1)
    }
    .frame(maxWidth: .infinity)
  }
}

private enum QuotaColors {
  static func color(_ w: QuotaWindowView?, _ tint: Color, dimmed: Bool) -> Color {
    if dimmed { return Theme.textTertiary }
    guard let used = w?.usedPct else { return tint }
    return used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : tint
  }

  /// Today: "4:20 PM"; within six days: "Fri 4:20 PM"; later: "Nov 3".
  static func clock(_ date: Date, now: Date) -> String {
    let f = DateFormatter()
    if Calendar.current.isDate(date, inSameDayAs: now) {
      f.setLocalizedDateFormatFromTemplate("jmm")
    } else if date.timeIntervalSince(now) < 6 * 86400 {
      f.setLocalizedDateFormatFromTemplate("EEEjmm")
    } else {
      f.setLocalizedDateFormatFromTemplate("MMMd")
    }
    return f.string(from: date)
  }
}
