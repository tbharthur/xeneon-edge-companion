import EdgeCore
import SwiftUI

/// The meeting recorder: record/stop (the same path as the Poly button), the running time while
/// recording, transcription progress, the Discord hand-off, and how the last call ended. A second,
/// equal button mutes the microphone for every app, recording or not. A pair of phone buttons
/// answers and hangs up iPhone calls taken on the Mac (Answer opens the Phone app otherwise).
struct RecorderWidget: View {
  @ObservedObject private var service = RecorderService.shared
  @ObservedObject private var mic = MicController.shared
  @ObservedObject private var phone = PhoneController.shared
  @State private var confirmStop = false
  @State private var pulse = false
  @State private var ring = false

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
      phone.retain()
    }
    .onDisappear {
      service.release()
      mic.release()
      phone.release()
    }
  }

  /// A wide or square card: Record/Stop, the mic, then the phone pair stacked, each with its
  /// words underneath. The circles grow to whatever the card leaves after the header and captions.
  private func sideBySide(_ size: CGSize) -> some View {
    let column = (size.width - Self.columnGap * 2) / 3
    let control = max(64, min(column - 12, size.height - 40 - Self.captionHeight - 12, 160))
    let phoneCircle = max(44, min(control * 0.72, (size.height - 40 - 2 * (Self.phoneCaptionHeight + 8) - 10) / 2))
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
        VStack(spacing: 10) {
          phoneControl(answer: true, size: phoneCircle)
          phoneControl(answer: false, size: phoneCircle)
        }
        .frame(width: column)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// A tall, narrow card: Record/Stop and the mic each in their own panel, stacked, with the
  /// last call in a strip underneath while idle.
  private func stacked(_ size: CGSize) -> some View {
    VStack(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          title
          Spacer(minLength: 2)
          statusPill
        }
        VStack(alignment: .leading, spacing: 6) {
          title
          statusPill
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      panel(fill: recordFill) { circle in
        VStack(spacing: 10) {
          primary(size: circle)
          stackedDetail.multilineTextAlignment(.center)
        }
      }
      panel(fill: mic.muted == true ? Theme.warning.opacity(0.14) : Self.panelFill) { circle in
        VStack(spacing: 10) {
          micButton(size: circle)
          micCaption.multilineTextAlignment(.center)
        }
      }
      phonePanel(width: size.width)
      if case let .idle(last?) = service.phase {
        lastCallStrip(last)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .top)
  }

  private var title: some View {
    Text(tr("통화 녹음", "Call recorder")).font(Theme.text(17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
      .lineLimit(1).minimumScaleFactor(0.7)
  }

  private static let panelFill = Color.white.opacity(0.04)
  /// Room under each circle in a panel for its words.
  private static let panelCaptionHeight: CGFloat = 62

  private var recordFill: Color {
    switch service.phase {
    case .recording: Theme.critical.opacity(0.13)
    case .transcribing, .sending: Theme.netIn.opacity(0.10)
    default: Self.panelFill
    }
  }

  /// A rounded panel whose circle grows to what the panel leaves after its words.
  private func panel<Content: View>(fill: Color, @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
    GeometryReader { g in
      let circle = max(60, min(g.size.width - 36, g.size.height - Self.panelCaptionHeight - 30, 150))
      content(circle)
        .frame(width: g.size.width, height: g.size.height)
    }
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
    .animation(.easeInOut(duration: 0.25), value: fill)
  }

  /// Words under the record control in the stacked layout; the last call has its own strip.
  @ViewBuilder private var stackedDetail: some View {
    if case .idle = service.phase {
      Text(tr("녹음 시작", "Record")).font(Theme.text(20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    } else {
      detail
    }
  }

  private func lastCallStrip(_ last: RecorderLastRun) -> some View {
    let outcome = Self.outcome(last.outcome)
    var parts: [String] = []
    if let ended = last.endedAt { parts.append(clock(ended)) }
    if let secs = last.audioSeconds { parts.append(duration(secs)) }
    return VStack(alignment: .leading, spacing: 4) {
      Text(tr("마지막 통화", "Last call").uppercased()).font(Theme.text(10.5, weight: .bold)).tracking(0.8)
        .foregroundStyle(Theme.textTertiary)
      if !parts.isEmpty {
        Text(parts.joined(separator: " · ")).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
          .lineLimit(1).minimumScaleFactor(0.8)
      }
      Label(outcome.text, systemImage: outcome.symbol).font(Theme.text(13, weight: .semibold)).foregroundStyle(outcome.color)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.panelFill))
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

  // MARK: Phone

  private static let phoneGap: CGFloat = 12
  private static let phoneCaptionHeight: CGFloat = 20

  /// The phone pair side by side in its own panel, sized from the card's width (and capped so
  /// Record and the mic keep the larger circles).
  private func phonePanel(width: CGFloat) -> some View {
    let circle = max(44, min((width - 28 - Self.phoneGap) / 2, 84))
    return HStack(alignment: .top, spacing: Self.phoneGap) {
      phoneControl(answer: true, size: circle)
      phoneControl(answer: false, size: circle)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(phoneFill))
    .animation(.easeInOut(duration: 0.25), value: phone.state)
  }

  private var phoneFill: Color {
    switch phone.state {
    case .ringing: Theme.battery.opacity(0.16)
    case .active: Theme.battery.opacity(0.08)
    case .idle: Self.panelFill
    }
  }

  private func phoneControl(answer: Bool, size: CGFloat) -> some View {
    VStack(spacing: 8) {
      if answer { answerButton(size: size) } else { hangUpButton(size: size) }
      phoneCaption(answer: answer, size: size)
        .frame(height: Self.phoneCaptionHeight)
    }
    .frame(width: size + Self.phoneGap)
  }

  /// Answers a ringing call; otherwise opens (or launches) the Phone app.
  private func answerButton(size: CGFloat) -> some View {
    let ringing = phone.canAnswer
    return Button { phone.answer() } label: {
      ZStack {
        if ringing {
          Circle().stroke(Theme.battery, lineWidth: 3)
            .scaleEffect(ring ? 1.22 : 1)
            .opacity(ring ? 0 : 0.9)
            .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: ring)
            .onAppear { ring = true }
            .onDisappear { ring = false }
        }
        Circle().fill(ringing ? Theme.battery : Color.white.opacity(0.16))
        Circle().strokeBorder(Color.white.opacity(ringing ? 0.18 : 0.28), lineWidth: 3)
        Image(systemName: "phone.fill")
          .font(.system(size: size * 0.36, weight: .semibold))
          .foregroundStyle(ringing ? Color.black.opacity(0.85) : Theme.battery)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
  }

  /// Declines a ringing call or ends the current one; dimmed with no call.
  private func hangUpButton(size: CGFloat) -> some View {
    let available = phone.canHangUp
    return Button { phone.hangUp() } label: {
      ZStack {
        Circle().fill(available ? Theme.critical.opacity(0.9) : Color.white.opacity(0.06))
        Circle().strokeBorder(Color.white.opacity(available ? 0.18 : 0.12), lineWidth: 3)
        Image(systemName: "phone.down.fill")
          .font(.system(size: size * 0.34, weight: .semibold))
          .foregroundStyle(available ? Color.white : Color.white.opacity(0.3))
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!available)
  }

  @ViewBuilder private func phoneCaption(answer: Bool, size: CGFloat) -> some View {
    let font = Theme.text(size < 60 ? 14 : 16, weight: .semibold)
    if !answer, !phone.trusted {
      // Without Accessibility the call can't be read; Answer still opens Phone.
      Button { phone.openAccessibilitySettings() } label: {
        Text(tr("권한 필요", "Allow access")).font(font).foregroundStyle(Theme.warning)
          .lineLimit(1).minimumScaleFactor(0.6)
      }
      .buttonStyle(.plain)
    } else {
      let (text, color): (String, Color) = switch (answer, phone.state) {
      case (true, .ringing): phone.canAnswer ? (tr("받기", "Answer"), Theme.battery) : (tr("전화", "Phone"), Theme.textPrimary)
      case (true, .active): (tr("통화 중", "On call"), Theme.battery)
      case (true, .idle): (tr("전화", "Phone"), Theme.textPrimary)
      case (false, .ringing): (tr("거절", "Decline"), phone.canHangUp ? Theme.critical : Theme.textTertiary)
      case (false, _): (tr("끊기", "Hang Up"), phone.canHangUp ? Theme.critical : Theme.textTertiary)
      }
      Text(text).font(font).foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.6)
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
    let (text, symbol, color) = Self.outcome(last.outcome)
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

  static func outcome(_ outcome: RecorderLastRun.Outcome) -> (text: String, symbol: String, color: Color) {
    switch outcome {
    case .sent: (tr("Discord로 보냄", "Sent to Discord"), "checkmark.circle.fill", Theme.battery)
    case .undelivered: (tr("받아쓰기만 저장됨", "Saved, not sent"), "exclamationmark.triangle.fill", Theme.warning)
    case .empty: (tr("소리가 녹음되지 않음", "No audio captured"), "exclamationmark.triangle.fill", Theme.warning)
    case .failed: (tr("녹음 실패", "Recording failed"), "xmark.octagon.fill", Theme.critical)
    case .startFailed: (tr("시작 실패", "Didn't start"), "xmark.octagon.fill", Theme.critical)
    case let .other(s): (s, "questionmark.circle", Theme.textTertiary)
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
