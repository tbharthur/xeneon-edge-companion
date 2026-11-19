import EdgeCore
import SwiftUI

/// Calls and sound in one card, with no title: the phone pair on top (answer or open Phone, and
/// decline or hang up iPhone calls taken on the Mac), the meeting recorder under it with the last
/// call beside the Record key, and a row of channel strips filling the rest: the mic mute (every
/// physical mic, for every app), the desk monitor's speakers and the Sonos speaker, each with its
/// mute key along the bottom.
struct CallSoundWidget: View {
  @ObservedObject private var recorder = RecorderService.shared
  @ObservedObject private var mic = MicController.shared
  @ObservedObject private var phone = PhoneController.shared
  @ObservedObject private var monitor = MonitorVolumeController.shared
  @ObservedObject private var sonos = SonosVolumeController.shared

  var body: some View {
    WidgetCard {
      CallSoundCard(state: state, actions: actions)
    }
    .onAppear {
      recorder.retain()
      mic.retain()
      phone.retain()
      monitor.retain()
      sonos.retain()
    }
    .onDisappear {
      recorder.release()
      mic.release()
      phone.release()
      monitor.release()
      sonos.release()
    }
  }

  private var state: CallSoundState {
    CallSoundState(
      call: phone.state, canAnswer: phone.canAnswer, canHangUp: phone.canHangUp, phoneTrusted: phone.trusted,
      recorder: recorder.phase, request: recorder.requested, recorderError: recorder.error, now: recorder.now,
      micMuted: mic.muted, micName: mic.deviceName,
      monitor: FaderChannelState(name: monitor.shortName, level: monitor.level, muted: monitor.muted,
                                 ready: monitor.status == .ready, unreachable: monitor.status == .unavailable),
      sonos: FaderChannelState(name: "Sonos", level: sonos.level, muted: sonos.muted,
                               ready: sonos.status == .ready, unreachable: sonos.status == .unavailable,
                               needsPermission: sonos.status == .denied,
                               place: sonos.room.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sonos.room))
  }

  private var actions: CallSoundActions {
    CallSoundActions(
      answer: { phone.answer() }, hangUp: { phone.hangUp() }, allowAccess: { phone.openAccessibilitySettings() },
      record: { recorder.start() }, stop: { recorder.stop() }, toggleMic: { mic.toggle() },
      monitor: FaderChannelActions(set: { monitor.set($0) }, drag: { monitor.drag(dy: $0, travel: $1) }, toggleMute: { monitor.toggleMute() }),
      sonos: FaderChannelActions(set: { sonos.set($0) }, drag: { sonos.drag(dy: $0, travel: $1) }, toggleMute: { sonos.toggleMute() },
                                 allow: { sonos.openLocalNetworkSettings() }))
  }
}

extension MonitorVolumeController {
  /// "LG ULTRAWIDE" → "LG"; other names as they are.
  var shortName: String {
    guard let name, !name.isEmpty else { return tr("모니터", "Monitor") }
    if name.uppercased().hasPrefix("LG ") { return "LG" }
    return name
  }
}

/// Everything the card shows, read from the phone, recorder, mic and volume controllers.
struct CallSoundState {
  var call: PhoneCallState = .idle
  var canAnswer = false
  var canHangUp = false
  var phoneTrusted = true
  var recorder: RecorderPhase = .idle(last: nil)
  var request: RecorderService.Request?
  var recorderError: String?
  var now = Date()
  /// nil: no mic the control can mute.
  var micMuted: Bool?
  var micName: String?
  var monitor = FaderChannelState(name: "LG")
  var sonos = FaderChannelState(name: "Sonos")
}

struct FaderChannelState {
  var name: String
  /// 0...1; nil before the first reading.
  var level: Double?
  var muted: Bool?
  /// A reading has arrived, so the fader and mute key work.
  var ready = false
  var unreachable = false
  /// macOS hasn't allowed the app to reach it (Local Network privacy).
  var needsPermission = false
  /// Where the speaker is, shown when it can't be reached ("Office").
  var place: String?
}

struct FaderChannelActions {
  var set: (Double) -> Void = { _ in }
  var drag: (Double, Double) -> Void = { _, _ in }
  var toggleMute: () -> Void = {}
  /// Opens the setting that lets the app reach the speaker.
  var allow: () -> Void = {}
}

struct CallSoundActions {
  var answer: () -> Void = {}
  var hangUp: () -> Void = {}
  var allowAccess: () -> Void = {}
  var record: () -> Void = {}
  var stop: () -> Void = {}
  var toggleMic: () -> Void = {}
  var monitor = FaderChannelActions()
  var sonos = FaderChannelActions()
}

/// The card's contents for a given state; sizes come from `CallCardLayout`.
struct CallSoundCard: View {
  let state: CallSoundState
  let actions: CallSoundActions
  @State private var confirmStop = false
  @State private var pulse = false
  @State private var ring = false

  private static let keyRadius: CGFloat = 14
  private static let keyFill = Color.white.opacity(0.08)
  private static let idleFill = Color.white.opacity(0.05)
  private static let panelFill = Color.white.opacity(0.04)
  /// Dark ink on a solid green, red or amber key: the card colour.
  private static let ink = Theme.card

  var body: some View {
    GeometryReader { geo in
      let layout = CallCardLayout(width: geo.size.width, height: geo.size.height)
      ZStack(alignment: .topLeading) {
        VStack(spacing: CallCardLayout.rowGap) {
          phoneRow(layout)
          recordPanel(layout)
        }
        .frame(width: layout.controls.width, height: layout.controls.height, alignment: .topLeading)
        .offset(x: layout.controls.minX, y: layout.controls.minY)
        soundRow(layout)
          .frame(width: layout.sound.width, height: layout.sound.height, alignment: .topLeading)
          .offset(x: layout.sound.minX, y: layout.sound.minY)
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }
  }

  // MARK: Keys

  /// A rounded key with a glyph over a word; in a short card the glyph beside the word, or alone
  /// when the key is narrow too.
  private func key<Glyph: View>(_ title: String, fill: Color, ink: Color, bold: Bool = false, width: CGFloat, height: CGFloat,
                                @ViewBuilder glyph: () -> Glyph) -> some View {
    let label = Text(title).font(Theme.text(17, weight: bold ? .bold : .semibold)).foregroundStyle(ink)
      .lineLimit(1).minimumScaleFactor(0.6)
    return Group {
      if height < 90, width < 100 {
        // Too small for words: the glyph alone.
        glyph().scaleEffect(0.7).frame(width: 32, height: 32)
      } else if height < 90 {
        HStack(spacing: 6) {
          glyph().scaleEffect(0.7).frame(width: 32, height: 32)
          label
        }
      } else {
        VStack(spacing: 8) {
          glyph().frame(height: 44)
          label
        }
      }
    }
    .padding(.horizontal, 6)
    .frame(width: width, height: height)
    .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(fill))
    .contentShape(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous))
  }

  private func phoneGlyph(_ name: String, _ color: Color) -> some View {
    Image(systemName: name).font(.system(size: 28, weight: .semibold)).foregroundStyle(color)
  }

  // MARK: Phone

  private func phoneRow(_ layout: CallCardLayout) -> some View {
    HStack(spacing: CallCardLayout.rowGap) {
      answerKey(width: layout.keyWidth, height: layout.rowHeight)
      hangUpKey(width: layout.keyWidth, height: layout.rowHeight)
    }
    .animation(.easeInOut(duration: 0.25), value: state.call)
  }

  /// Answers a ringing call; otherwise opens (or launches) the Phone app.
  private func answerKey(width: CGFloat, height: CGFloat) -> some View {
    let ringing = state.call == .ringing && state.canAnswer
    return Button(action: actions.answer) {
      ZStack {
        if ringing {
          RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).stroke(Theme.battery, lineWidth: 3)
            .scaleEffect(ring ? 1.08 : 1)
            .opacity(ring ? 0 : 0.9)
            .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: ring)
            .onAppear { ring = true }
            .onDisappear { ring = false }
        }
        if ringing {
          key(tr("받기", "Answer"), fill: Theme.battery, ink: Self.ink, bold: true, width: width, height: height) {
            phoneGlyph("phone.fill", Self.ink)
          }
        } else if state.call == .active {
          key(tr("통화 중", "On call"), fill: Theme.battery.opacity(0.16), ink: Theme.battery, width: width, height: height) {
            phoneGlyph("phone", Theme.battery)
          }
        } else {
          key(tr("전화", "Phone"), fill: Self.keyFill, ink: Theme.textPrimary, width: width, height: height) {
            phoneGlyph("phone", Theme.battery)
          }
        }
      }
      .frame(width: width, height: height)
    }
    .buttonStyle(PressableStyle())
  }

  /// Declines a ringing call or ends the current one; dimmed with no call. Without Accessibility
  /// no call can be read, so it asks for access instead.
  @ViewBuilder private func hangUpKey(width: CGFloat, height: CGFloat) -> some View {
    if !state.phoneTrusted {
      Button(action: actions.allowAccess) {
        key(tr("권한 필요", "Allow access"), fill: Theme.warning.opacity(0.16), ink: Theme.warning, width: width, height: height) {
          phoneGlyph("lock.shield", Theme.warning)
        }
      }
      .buttonStyle(PressableStyle())
    } else {
      let live = state.canHangUp
      let title = state.call == .ringing ? tr("거절", "Decline") : tr("끊기", "Hang up")
      Button(action: actions.hangUp) {
        key(title, fill: live ? Theme.critical : Self.idleFill, ink: live ? Self.ink : Theme.textTertiary, bold: live,
            width: width, height: height) {
          phoneGlyph("phone.down", live ? Self.ink : Theme.textTertiary)
        }
      }
      .buttonStyle(PressableStyle())
      .disabled(!live)
    }
  }

  // MARK: Recorder

  private var recordTint: Color {
    switch state.recorder {
    case .recording: Theme.critical.opacity(0.10)
    case .transcribing, .sending: Theme.netIn.opacity(0.10)
    default: Self.panelFill
    }
  }

  /// The Record/Stop key and, beside it, what the recorder is doing or how the last call ended.
  private func recordPanel(_ layout: CallCardLayout) -> some View {
    HStack(spacing: 0) {
      recordKey(width: layout.keyWidth, height: layout.rowHeight)
      readout
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    .frame(width: layout.controls.width, height: layout.rowHeight)
    .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(recordTint))
    .animation(.easeInOut(duration: 0.25), value: recordTint)
  }

  /// The record button's 44-point mark: a red dot, or a red dot holding a white square to stop.
  private func recordMark(stop: Bool) -> some View {
    ZStack {
      Circle().fill(Theme.critical)
      if stop {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white).frame(width: 16, height: 16)
      } else {
        Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 3)
      }
    }
    .frame(width: 44, height: 44)
  }

  private var spinner: some View {
    ProgressView().controlSize(.large).tint(Theme.textSecondary)
  }

  @ViewBuilder private func recordKey(width: CGFloat, height: CGFloat) -> some View {
    switch state.recorder {
    case .idle:
      let busy = state.request == .start
      Button(action: actions.record) {
        key(tr("녹음", "Record"), fill: Self.keyFill, ink: Theme.textPrimary, width: width, height: height) {
          if busy { spinner } else { recordMark(stop: false) }
        }
      }
      .buttonStyle(PressableStyle())
      .disabled(busy)
    case .recording:
      // Stop takes two taps within three seconds.
      let busy = state.request == .stop
      Button {
        if confirmStop {
          confirmStop = false
          actions.stop()
        } else {
          confirmStop = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmStop = false }
        }
      } label: {
        key(confirmStop ? tr("한 번 더", "Tap again") : tr("중지", "Stop"), fill: Theme.critical.opacity(confirmStop ? 0.4 : 0.22),
            ink: Theme.textPrimary, bold: confirmStop, width: width, height: height) {
          if busy { spinner } else { recordMark(stop: true) }
        }
      }
      .buttonStyle(PressableStyle())
      .disabled(busy)
    case let .transcribing(progress, _):
      let ringSize = min(height - 20, width - 20, 76)
      ZStack {
        RingGauge(value: progress ?? 0, tint: Theme.netIn, lineWidth: 7)
        Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
          .font(Theme.number(ringSize * 0.26, weight: .bold)).foregroundStyle(Theme.textPrimary)
      }
      .frame(width: ringSize, height: ringSize)
      .frame(width: width, height: height)
      .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(Self.keyFill))
    case .starting, .sending:
      spinner
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(Self.keyFill))
    }
  }

  private func caption(_ text: String, _ color: Color = Theme.textSecondary) -> some View {
    Text(text.uppercased()).font(Theme.text(11, weight: .semibold)).tracking(0.66).foregroundStyle(color)
      .lineLimit(1).minimumScaleFactor(0.8)
  }

  private func errorText(_ error: String, lines: Int) -> some View {
    Text(error).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.warning)
      .lineLimit(lines).minimumScaleFactor(0.8)
  }

  /// Right of the record key: always about the most recent recording.
  @ViewBuilder private var readout: some View {
    let error = state.recorderError
    switch state.recorder {
    case let .idle(last):
      if let error {
        errorText(error, lines: 4)
      } else if let last {
        lastRun(last)
      }
    case .starting:
      VStack(alignment: .leading, spacing: 5) {
        if let error { errorText(error, lines: 2) }
        Text(tr("녹음기 준비 중…", "Getting the recorder ready…")).font(Theme.text(15, weight: .semibold))
          .foregroundStyle(Theme.textSecondary).lineLimit(3).minimumScaleFactor(0.8)
      }
    case let .recording(since):
      VStack(alignment: .leading, spacing: 6) {
        if let error {
          errorText(error, lines: 2)
        } else {
          HStack(spacing: 6) {
            Circle().fill(Theme.critical).frame(width: 8, height: 8)
              .opacity(pulse ? 0.3 : 1)
              .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
              .onAppear { pulse = true }
              .onDisappear { pulse = false }
            Text(confirmStop ? tr("한 번 더 누르면 중지", "Tap again to stop") : tr("녹음 중", "Recording"))
              .font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.critical)
              .lineLimit(2).minimumScaleFactor(0.8)
          }
        }
        Text(elapsed(since)).font(Theme.number(38, weight: .bold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.5)
      }
    case let .transcribing(_, audioSeconds):
      VStack(alignment: .leading, spacing: 5) {
        if let error { errorText(error, lines: 2) } else { caption(tr("받아쓰는 중", "Transcribing"), Theme.netIn) }
        if let audioSeconds {
          Text(tr("녹음 \(duration(audioSeconds))", "\(duration(audioSeconds)) call")).font(Theme.text(15, weight: .semibold))
            .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
        }
        Text(tr("끝나면 Discord로 보내요", "Then off to Discord")).font(Theme.text(13, weight: .medium))
          .foregroundStyle(Theme.textSecondary).lineLimit(2).minimumScaleFactor(0.8)
      }
    case .sending:
      VStack(alignment: .leading, spacing: 5) {
        if let error { errorText(error, lines: 2) }
        Text(tr("Discord로 보내는 중…", "Sending to Discord…")).font(Theme.text(15, weight: .semibold))
          .foregroundStyle(Theme.textSecondary).lineLimit(3).minimumScaleFactor(0.8)
      }
    }
  }

  private func lastRun(_ last: RecorderLastRun) -> some View {
    let outcome = Self.outcome(last.outcome)
    var parts: [String] = []
    if let ended = last.endedAt { parts.append(clock(ended)) }
    if let secs = last.audioSeconds { parts.append(duration(secs)) }
    return VStack(alignment: .leading, spacing: 5) {
      caption(tr("마지막 통화", "Last call"))
      if !parts.isEmpty {
        Text(parts.joined(separator: " · ")).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.75)
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Image(systemName: outcome.symbol).font(.system(size: 12, weight: .bold))
        Text(outcome.text).font(Theme.text(13, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
      }
      .foregroundStyle(outcome.color)
    }
  }

  static func outcome(_ outcome: RecorderLastRun.Outcome) -> (text: String, symbol: String, color: Color) {
    switch outcome {
    case .sent: (tr("Discord로 보냄", "Sent to Discord"), "checkmark", Theme.battery)
    case .undelivered: (tr("받아쓰기만 저장됨", "Saved, not sent"), "exclamationmark.triangle.fill", Theme.warning)
    case .empty: (tr("소리가 녹음되지 않음", "No audio captured"), "exclamationmark.triangle.fill", Theme.warning)
    case .failed: (tr("녹음 실패", "Recording failed"), "xmark.octagon.fill", Theme.critical)
    case .startFailed: (tr("시작 실패", "Didn't start"), "xmark.octagon.fill", Theme.critical)
    case let .other(s): (s, "questionmark.circle", Theme.textTertiary)
    }
  }

  private func elapsed(_ since: Date?) -> String {
    guard let since else { return "–:––" }
    let total = max(0, Int(state.now.timeIntervalSince(since)))
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

  // MARK: Sound

  /// Equal channel strips across the sound section: the mic, then a fader per speaker. A card too
  /// narrow for all three puts the mic in a bar above the faders.
  @ViewBuilder private func soundRow(_ layout: CallCardLayout) -> some View {
    let strip = layout.faderStrip(channels: 3)
    if layout.micOnTop(channels: 3) {
      VStack(spacing: CallCardLayout.channelGap(count: 2)) {
        micBar(width: layout.sound.width, height: layout.micBar)
        HStack(spacing: CallCardLayout.channelGap(count: 2)) {
          speakerStrips(width: strip.width, metrics: layout.strip(height: strip.height))
        }
        .frame(height: strip.height)
      }
      .frame(width: layout.sound.width, height: layout.sound.height, alignment: .topLeading)
    } else {
      HStack(spacing: CallCardLayout.channelGap(count: 3)) {
        micStrip(width: strip.width, height: strip.height)
        speakerStrips(width: strip.width, metrics: layout.strip(height: strip.height))
      }
      .frame(width: layout.sound.width, height: layout.sound.height, alignment: .topLeading)
    }
  }

  @ViewBuilder private func speakerStrips(width: CGFloat, metrics: CallCardLayout.Strip) -> some View {
    FaderStrip(channel: state.monitor, actions: actions.monitor, tint: Theme.gpu,
               unreachable: tr("모니터 볼륨을 읽을 수 없어요", "Can't reach the monitor's volume"),
               unreachableSymbol: "speaker.slash", metrics: metrics)
      .frame(width: width)
    FaderStrip(channel: state.sonos, actions: actions.sonos, tint: Theme.netIn,
               unreachable: state.sonos.place == nil ? tr("설정에서 Sonos 방을 정하세요", "Choose a Sonos room in Settings")
                 : tr("잠들었거나 자리에 없어요", "Asleep or away"),
               unreachableSymbol: "moon.zzz", metrics: metrics)
      .frame(width: width)
  }

  private var micStatus: String {
    state.micMuted == nil ? tr("마이크 없음", "No mic") : state.micMuted == true ? tr("음소거됨", "Muted") : tr("마이크 켜짐", "Mic on")
  }

  private func micCircle(_ size: CGFloat) -> some View {
    let muted = state.micMuted == true
    return ZStack {
      Circle().fill(muted ? Theme.warning : Color.white.opacity(state.micMuted != nil ? 0.16 : 0.06))
      Image(systemName: muted ? "mic.slash" : "mic")
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(muted ? Self.ink : Theme.textPrimary)
    }
    .frame(width: size, height: size)
  }

  private var micFill: Color {
    state.micMuted == true ? Theme.warning.opacity(0.16) : state.micMuted != nil ? Self.keyFill : Self.idleFill
  }

  /// The mic as a bar across a narrow card.
  private func micBar(width: CGFloat, height: CGFloat) -> some View {
    let muted = state.micMuted == true
    let available = state.micMuted != nil
    return Button(action: actions.toggleMic) {
      HStack(spacing: 10) {
        micCircle(44)
        VStack(alignment: .leading, spacing: 2) {
          Text(micStatus).font(Theme.text(15, weight: muted ? .bold : .semibold))
            .foregroundStyle(muted ? Theme.warning : Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
          if let name = state.micName {
            Text(name).font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
              .lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(width: width, height: height)
      .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(micFill))
      .contentShape(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous))
    }
    .buttonStyle(PressableStyle())
    .disabled(!available)
    .opacity(available ? 1 : 0.5)
  }

  /// The whole strip is one key that mutes every physical mic at the device, so Teams, Zoom, Meet
  /// and the phone all go quiet.
  private func micStrip(width: CGFloat, height: CGFloat) -> some View {
    let muted = state.micMuted == true
    let available = state.micMuted != nil
    let circle = max(44, min(84, width - 24, height - 120))
    return Button(action: actions.toggleMic) {
      VStack(spacing: 0) {
        Text(tr("마이크", "Mic")).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        Spacer(minLength: 6)
        micCircle(circle)
        Spacer(minLength: 6)
        VStack(spacing: 4) {
          Text(micStatus)
            .font(Theme.text(17, weight: muted ? .bold : .semibold))
            .foregroundStyle(muted ? Theme.warning : Theme.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.7)
          if let name = state.micName {
            Text(name).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
              .lineLimit(2).minimumScaleFactor(0.75).multilineTextAlignment(.center)
          }
        }
      }
      .padding(.vertical, 16)
      .padding(.horizontal, width < 110 ? 6 : 8)
      .frame(width: width, height: height)
      .background(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous).fill(micFill))
      .contentShape(RoundedRectangle(cornerRadius: Self.keyRadius, style: .continuous))
    }
    .buttonStyle(PressableStyle())
    .disabled(!available)
    .opacity(available ? 1 : 0.5)
    .animation(.easeInOut(duration: 0.2), value: muted)
  }
}

/// A mixing-desk channel strip for one speaker: its name and level on top, a long fader, and a
/// Mute key that lights red. Muted, the level greys out with a red strike.
private struct FaderStrip: View {
  let channel: FaderChannelState
  let actions: FaderChannelActions
  let tint: Color
  let unreachable: String
  let unreachableSymbol: String
  let metrics: CallCardLayout.Strip

  var body: some View {
    VStack(spacing: CallCardLayout.Strip.spacing) {
      if channel.needsPermission {
        Button(action: actions.allow) { away(Text(tr("설정에서 로컬 네트워크 허용", "Allow Local Network in Settings")), symbol: "lock.shield", ink: Theme.warning) }
          .buttonStyle(PressableStyle())
      } else if channel.unreachable {
        away(Text(unreachable), symbol: unreachableSymbol, ink: Theme.textTertiary)
      } else {
        readout.frame(height: metrics.header)
        if metrics.fader > 0 {
          Fader(level: channel.level ?? 0, muted: channel.muted == true, enabled: channel.ready, tint: tint,
                set: actions.set, drag: actions.drag)
            .frame(height: metrics.fader)
        }
        muteKey.frame(height: metrics.muteKey)
      }
    }
  }

  /// The name over the level; in a short strip, one line holding just the level.
  private var readout: some View {
    let compact = metrics.header < 44
    // One Text, so a narrow strip scales the number and its % together.
    let level = (Text(channel.level.map { "\(Int(($0 * 100).rounded()))" } ?? "–").font(Theme.number(compact ? 18 : 30, weight: .bold))
      + Text(channel.level == nil ? "" : "%").font(Theme.number(compact ? 11 : 14, weight: .semibold)).foregroundColor(Theme.textSecondary))
      .foregroundStyle(channel.muted == true ? Theme.textTertiary : Theme.textPrimary)
      .strikethrough(channel.muted == true, color: Theme.critical)
      .lineLimit(1).minimumScaleFactor(0.5)
    return VStack(spacing: 3) {
      if !compact {
        Text(channel.name).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
          .lineLimit(1).minimumScaleFactor(0.7)
      }
      level
    }
    .frame(maxWidth: .infinity)
  }

  private var muteKey: some View {
    let on = channel.muted == true
    let short = metrics.muteKey < 52
    return Button(action: actions.toggleMute) {
      VStack(spacing: 6) {
        Image(systemName: on ? "speaker.slash" : "speaker.wave.2").font(.system(size: short ? 16 : 19, weight: .semibold))
        if !short {
          Text(on ? tr("음소거됨", "Muted") : tr("음소거", "Mute")).font(Theme.text(13, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.7)
        }
      }
      .foregroundStyle(on ? Color.white : Theme.textPrimary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(on ? Theme.critical : Color.white.opacity(0.08))
          .shadow(color: on ? Theme.critical.opacity(0.55) : .clear, radius: 10)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
    .disabled(!channel.ready)
  }

  /// Out of reach: said calmly, in the strip's own space, until the next reading brings it back.
  @ViewBuilder private func away(_ message: Text, symbol: String, ink: Color) -> some View {
    if metrics.total < 160 {
      // A short strip: the sign and the message only.
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
        message.font(Theme.text(11, weight: .medium)).foregroundStyle(ink).lineLimit(3).minimumScaleFactor(0.7)
      }
      .multilineTextAlignment(.center)
      .padding(6)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    } else {
      fullAway(message, symbol: symbol, ink: ink)
    }
  }

  private func fullAway(_ message: Text, symbol: String, ink: Color) -> some View {
    VStack(spacing: 8) {
      Text(channel.name).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        .lineLimit(1).minimumScaleFactor(0.7)
      Spacer(minLength: 0)
      Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(ink)
      if let place = channel.place {
        Text(place).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
          .lineLimit(2).minimumScaleFactor(0.7)
      }
      message.font(Theme.text(13, weight: .medium)).foregroundStyle(ink)
        .lineLimit(4).minimumScaleFactor(0.8)
      Spacer(minLength: 0)
    }
    .multilineTextAlignment(.center)
    .padding(.top, 16).padding(.bottom, 12).padding(.horizontal, 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
  }
}
