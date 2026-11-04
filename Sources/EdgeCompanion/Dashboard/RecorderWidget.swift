import EdgeCore
import SwiftUI

/// The meeting recorder: record/stop (the same path as the Poly button), the running time while
/// recording, transcription progress, the Discord hand-off, and how the last call ended. A second,
/// equal button mutes the microphone for every app, recording or not.
struct RecorderWidget: View {
  @ObservedObject private var service = RecorderService.shared
  @ObservedObject private var mic = MicController.shared
  @State private var confirmStop = false
  @State private var pulse = false

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        if geo.size.height > geo.size.width * 1.25 {
          stacked(geo.size)
        } else {
          sideBySide(geo.size)
        }
      }
    }
    .onAppear {
      service.retain()
      mic.retain()
    }
    .onDisappear {
      service.release()
      mic.release()
    }
  }

  /// A wide or square card: Record/Stop on the left, the mic on the right, each with its words
  /// underneath. The circles grow to whatever the card leaves after the header and captions.
  private func sideBySide(_ size: CGSize) -> some View {
    let column = (size.width - Self.columnGap) / 2
    let control = max(70, min(column - 16, size.height - 40 - Self.captionHeight - 12, 160))
    return VStack(alignment: .leading, spacing: 10) {
      header
      HStack(alignment: .top, spacing: Self.columnGap) {
        VStack(spacing: 12) {
          primary(size: control)
          detail.frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
        .frame(width: column)
        VStack(spacing: 12) {
          micButton(size: control)
          micCaption.frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
        .frame(width: column)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// A tall, narrow card: Record/Stop above the mic, each with its words underneath, the two
  /// halves splitting the height below the header.
  private func stacked(_ size: CGSize) -> some View {
    let headerHeight: CGFloat = 58
    let half = (size.height - headerHeight - 10) / 2
    let control = max(64, min(size.width - 12, half - Self.stackedCaptionHeight - 12, 170))
    return VStack(spacing: 10) {
      VStack(spacing: 6) {
        Text(tr("통화 녹음", "Call recorder")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.7)
        statusPill
      }
      .frame(maxWidth: .infinity)
      .frame(height: headerHeight - 10, alignment: .top)
      VStack(spacing: 12) {
        primary(size: control)
        detail.multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: half, alignment: .top)
      VStack(spacing: 12) {
        micButton(size: control)
        micCaption.multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: half, alignment: .top)
    }
    .frame(width: size.width, height: size.height, alignment: .top)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(tr("통화 녹음", "Call recorder")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
      Spacer(minLength: 4)
      statusPill
    }
    .frame(height: 30)
  }

  @ViewBuilder private var statusPill: some View {
    if let error = service.error {
      Pill(text: error, color: Theme.warning).lineLimit(1)
    } else {
      stateBadge
    }
  }

  private static let columnGap: CGFloat = 16
  /// Room kept under each circle for its words.
  private static let captionHeight: CGFloat = 74
  /// Room under each circle in the stacked layout, where long lines wrap instead of shrinking.
  private static let stackedCaptionHeight: CGFloat = 96

  /// Mute/unmute every microphone at the device, so Teams, Zoom, Meet and the rest all go quiet.
  private func micButton(size: CGFloat) -> some View {
    let muted = mic.muted == true
    let available = mic.muted != nil
    return Button { mic.toggle() } label: {
      ZStack {
        Circle().fill(muted ? Theme.warning : Color.white.opacity(available ? 0.16 : 0.06))
        Circle().strokeBorder(Color.white.opacity(muted ? 0.18 : 0.28), lineWidth: 3)
        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: size * 0.34, weight: .semibold))
          .foregroundStyle(muted ? Color.black.opacity(0.85) : .white)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!available)
    .opacity(available ? 1 : 0.5)
  }

  @ViewBuilder private var micCaption: some View {
    let muted = mic.muted == true
    VStack(spacing: 6) {
      Text(mic.muted == nil ? tr("마이크 없음", "No mic") : muted ? tr("음소거됨", "Muted") : tr("마이크 켜짐", "Mic on"))
        .font(Theme.text(20, weight: .semibold))
        .foregroundStyle(muted ? Theme.warning : Theme.textPrimary)
      if let name = mic.deviceName {
        Text(name).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.textTertiary)
          .lineLimit(1).minimumScaleFactor(0.75)
      }
    }
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

  /// Words under the record control.
  @ViewBuilder private var detail: some View {
    switch service.phase {
    case let .recording(since):
      VStack(spacing: 6) {
        Text(elapsed(since)).font(Theme.number(34, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
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
      VStack(spacing: 6) {
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
      VStack(spacing: 6) {
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
    return VStack(spacing: 3) {
      ViewThatFits(in: .horizontal) {
        Text(tr("마지막 통화", "Last call") + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")))
          .lineLimit(1)
        VStack(spacing: 1) {
          Text(tr("마지막 통화", "Last call"))
          if !parts.isEmpty { Text(parts.joined(separator: " · ")).lineLimit(1).minimumScaleFactor(0.8) }
        }
      }
      .font(Theme.text(13.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
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
