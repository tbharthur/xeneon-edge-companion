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
        // Side by side when there is room; stacked in a narrow card.
        let wide = geo.size.width >= geo.size.height * 1.15
        let control = min(wide ? geo.size.height - 46 : geo.size.width * 0.62, 150)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text(tr("통화 녹음", "Call recorder")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            if let error = service.error {
              Pill(text: error, color: Theme.warning).lineLimit(1)
            } else {
              stateBadge
            }
          }
          .frame(height: 30)
          Group {
            if wide {
              HStack(spacing: 22) {
                primary(size: control)
                detail.frame(maxWidth: .infinity, alignment: .leading)
              }
            } else {
              VStack(spacing: 14) {
                primary(size: control)
                detail.frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .onAppear { service.retain() }
    .onDisappear { service.release() }
  }

  @ViewBuilder private var stateBadge: some View {
    switch service.phase {
    case .recording: Pill(text: tr("녹음 중", "Live"), color: Theme.critical)
    case .starting: Pill(text: tr("시작 중", "Starting"), color: Theme.warning)
    case .transcribing: Pill(text: tr("받아쓰는 중", "Transcribing"), color: Theme.netIn)
    case .sending: Pill(text: tr("보내는 중", "Sending"), color: Theme.netIn)
    case .idle: EmptyView()
    }
  }

  /// The big round control: Record, Stop (tap twice), or the transcription ring.
  @ViewBuilder
  private func primary(size: CGFloat) -> some View {
    switch service.phase {
    case .recording:
      roundButton(size: size, color: Theme.critical, busy: service.requested == .stop) {
        if confirmStop {
          RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: size * 0.26, height: size * 0.26)
          Text(tr("한 번 더", "Tap again")).font(Theme.text(13, weight: .bold)).foregroundStyle(.white).offset(y: size * 0.28)
        } else {
          RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: size * 0.3, height: size * 0.3)
        }
      } action: {
        if confirmStop {
          confirmStop = false
          service.stop()
        } else {
          confirmStop = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmStop = false }
        }
      }
    case let .transcribing(progress, _):
      ZStack {
        RingGauge(value: progress ?? 0, tint: Theme.netIn, lineWidth: 10)
        Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…").font(Theme.number(size * 0.24, weight: .bold)).foregroundStyle(Theme.textPrimary)
      }
      .frame(width: size, height: size)
    case .starting, .sending:
      ZStack {
        Circle().stroke(Theme.track, lineWidth: 10).padding(5)
        ProgressView().controlSize(.large).tint(Theme.textSecondary)
      }
      .frame(width: size, height: size)
    case .idle:
      roundButton(size: size, color: Theme.critical, busy: service.requested == .start) {
        Circle().fill(.white).frame(width: size * 0.3, height: size * 0.3)
      } action: {
        service.start()
      }
    }
  }

  /// Words beside (or under) the control.
  @ViewBuilder private var detail: some View {
    switch service.phase {
    case let .recording(since):
      VStack(alignment: .leading, spacing: 6) {
        Text(elapsed(since)).font(Theme.number(46, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        HStack(spacing: 7) {
          Circle().fill(Theme.critical).frame(width: 10, height: 10)
            .opacity(pulse ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
          Text(confirmStop ? tr("한 번 더 누르면 중지", "Tap again to stop") : tr("녹음 중", "Recording"))
            .font(Theme.text(16, weight: .semibold)).foregroundStyle(Theme.critical)
        }
      }
    case let .transcribing(_, audioSeconds):
      VStack(alignment: .leading, spacing: 6) {
        Text(tr("받아쓰는 중", "Transcribing")).font(Theme.text(20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        if let audioSeconds {
          Text(tr("녹음 \(duration(audioSeconds))", "\(duration(audioSeconds)) call")).font(Theme.text(15, weight: .medium)).foregroundStyle(Theme.textSecondary)
        }
        Text(tr("끝나면 Discord로 보내요", "Then off to Discord")).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.textTertiary)
      }
    case .starting:
      Text(tr("녹음기 준비 중…", "Getting the recorder ready…")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textSecondary)
    case .sending:
      Text(tr("Discord로 보내는 중…", "Sending to Discord…")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textSecondary)
    case let .idle(last):
      VStack(alignment: .leading, spacing: 6) {
        Text(tr("녹음 시작", "Record")).font(Theme.text(20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        if let last {
          lastRun(last)
        } else {
          Text(tr("Poly 버튼과 같아요", "Same as the Poly button")).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.textTertiary)
        }
      }
    }
  }

  private func roundButton<Label: View>(size: CGFloat, color: Color, busy: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      ZStack {
        Circle().fill(color.opacity(busy ? 0.4 : 0.9))
        Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 3)
        if busy { ProgressView().controlSize(.large).tint(.white) } else { label() }
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(busy)
  }

  private func lastRun(_ last: RecorderLastRun) -> some View {
    let (text, symbol, color): (String, String, Color) = switch last.outcome {
    case .sent: (tr("Discord로 보냄", "Sent to Discord"), "checkmark.circle.fill", Theme.battery)
    case .undelivered: (tr("받아쓰기만 저장됨", "Saved, not sent"), "exclamationmark.triangle.fill", Theme.warning)
    case .empty: (tr("소리가 녹음되지 않음", "No audio captured"), "exclamationmark.triangle.fill", Theme.warning)
    case .failed: (tr("녹음 실패", "Recording failed"), "xmark.octagon.fill", Theme.critical)
    case .startFailed: (tr("시작 실패", "Didn't start"), "xmark.octagon.fill", Theme.critical)
    case let .other(s): (s, "questionmark.circle", Theme.textTertiary)
    }
    var parts: [String] = []
    if let ended = last.endedAt { parts.append(clock(ended)) }
    if let secs = last.audioSeconds { parts.append(duration(secs)) }
    return VStack(alignment: .leading, spacing: 3) {
      Text(tr("마지막 통화", "Last call") + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
        .font(Theme.text(13.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
      Label(text, systemImage: symbol).font(Theme.text(15, weight: .semibold)).foregroundStyle(color).lineLimit(2)
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
    if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
    return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
  }

  private func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "MMMd")
    return f.string(from: date)
  }
}
