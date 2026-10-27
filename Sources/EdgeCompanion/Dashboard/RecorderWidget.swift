import EdgeCore
import SwiftUI

/// The meeting recorder: record/stop (the same path as the Poly button), the running time while
/// recording, transcription progress, the Discord hand-off, and how the last call ended.
struct RecorderWidget: View {
  @ObservedObject private var service = RecorderService.shared
  @State private var confirmStop = false
  @State private var pulse = false

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let compact = geo.size.height < 200
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
          HStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(tr("통화 녹음", "Call recorder")).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            if let error = service.error {
              Text(error).font(Theme.text(11.5, weight: .medium)).foregroundStyle(Theme.warning).lineLimit(1)
            }
          }
          Spacer(minLength: 0)
          content(compact: compact)
          Spacer(minLength: 0)
        }
      }
    }
    .onAppear { service.retain() }
    .onDisappear { service.release() }
  }

  @ViewBuilder
  private func content(compact: Bool) -> some View {
    switch service.phase {
    case let .recording(since):
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Circle().fill(Theme.critical).frame(width: 12, height: 12)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
          Text(tr("녹음 중", "Recording")).font(Theme.text(15, weight: .semibold)).foregroundStyle(Theme.critical)
        }
        Text(elapsed(since)).font(Theme.number(compact ? 34 : 48, weight: .bold)).foregroundStyle(Theme.textPrimary)
        actionButton(
          title: confirmStop ? tr("한 번 더 눌러 중지", "Tap again to stop") : tr("중지", "Stop"),
          symbol: "stop.fill", color: Theme.critical, busy: service.requested == .stop
        ) {
          if confirmStop {
            confirmStop = false
            service.stop()
          } else {
            confirmStop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmStop = false }
          }
        }
      }
    case .starting:
      statusLine(tr("시작하는 중…", "Starting…"), color: Theme.warning, spinner: true)
    case let .transcribing(progress, audioSeconds):
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(tr("받아쓰는 중", "Transcribing")).font(Theme.text(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          Spacer(minLength: 4)
          Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…").font(Theme.number(compact ? 22 : 28, weight: .bold)).foregroundStyle(Theme.netIn)
        }
        UsageBar(value: progress ?? 0, tint: Theme.netIn, height: 8)
        if let audioSeconds {
          Text(tr("녹음 길이 \(duration(audioSeconds))", "\(duration(audioSeconds)) of audio")).font(Theme.text(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
        }
      }
    case .sending:
      statusLine(tr("Discord로 보내는 중…", "Sending to Discord…"), color: Theme.netIn, spinner: true)
    case let .idle(last):
      VStack(alignment: .leading, spacing: compact ? 8 : 12) {
        actionButton(title: tr("녹음 시작", "Record"), symbol: "record.circle", color: Theme.critical, busy: service.requested == .start) {
          service.start()
        }
        if let last {
          lastRun(last)
        }
      }
    }
  }

  private func statusLine(_ text: String, color: Color, spinner: Bool) -> some View {
    HStack(spacing: 10) {
      if spinner { ProgressView().controlSize(.small).tint(color) }
      Text(text).font(Theme.text(15, weight: .semibold)).foregroundStyle(color)
    }
  }

  private func actionButton(title: String, symbol: String, color: Color, busy: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if busy {
          ProgressView().controlSize(.small).tint(.white)
        } else {
          Image(systemName: symbol).font(.system(size: 16, weight: .bold))
        }
        Text(title).font(Theme.text(15, weight: .semibold))
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 46)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(busy ? 0.45 : 0.85)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(busy)
  }

  private func lastRun(_ last: RecorderLastRun) -> some View {
    let (text, color): (String, Color) = switch last.outcome {
    case .sent: (tr("Discord로 보냄", "Sent to Discord"), Theme.battery)
    case .undelivered: (tr("받아쓰기 저장됨 · Discord 전송 실패", "Transcript saved · Discord hand-off failed"), Theme.warning)
    case .empty: (tr("소리가 녹음되지 않음", "No audio captured"), Theme.warning)
    case .failed: (tr("녹음 실패", "Recording failed"), Theme.critical)
    case .startFailed: (tr("시작 실패", "Didn't start"), Theme.critical)
    case let .other(s): (s, Theme.textTertiary)
    }
    var parts: [String] = []
    if let ended = last.endedAt { parts.append(clock(ended)) }
    if let secs = last.audioSeconds { parts.append(duration(secs)) }
    return VStack(alignment: .leading, spacing: 3) {
      Text(text).font(Theme.text(13, weight: .semibold)).foregroundStyle(color).lineLimit(2)
      Text(tr("마지막 녹음", "Last") + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
        .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
    }
  }

  private func elapsed(_ since: Date?) -> String {
    guard let since else { return "–:––" }
    let total = max(0, Int(service.now.timeIntervalSince(since)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  private func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600 ? "\(total / 3600)h \((total % 3600) / 60)m" : "\(total / 60)m \(total % 60)s"
  }

  private func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "MMMd")
    return f.string(from: date)
  }
}
