import CoreAudio
import EdgeCore
import Foundation

/// Mutes and unmutes every physical microphone at the device level (see `MicMute`), and reads
/// the state back once a second while a widget that shows it is on screen, so a mute made
/// elsewhere (System Settings, the device itself) shows up too.
@MainActor
final class MicController: ObservableObject {
  static let shared = MicController()

  /// nil: no mic the control can mute.
  @Published private(set) var muted: Bool?
  @Published private(set) var deviceName: String?

  private var devices: [MicDevice] = []
  private var users = 0
  private var timer: Timer?

  func retain() {
    users += 1
    guard users == 1 else { return }
    refresh()
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    t.tolerance = 0.2
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }

  func toggle() {
    refresh()
    let on = MicMute.nextMuted(devices)
    var value: UInt32 = on ? 1 : 0
    for d in MicMute.targets(devices) {
      var addr = Self.muteAddress
      let status = AudioObjectSetPropertyData(d.id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
      if status != noErr { Log.error(.dashboard, "mic mute \(on) failed on \(d.name): \(status)") }
    }
    Log.info(.dashboard, "mic \(on ? "muted" : "unmuted")")
    refresh()
  }

  private func refresh() {
    devices = Self.inputDevices()
    let m = MicMute.isMuted(devices)
    if m != muted { muted = m }
    let name = MicMute.label(devices)
    if name != deviceName { deviceName = name }
  }

  // MARK: CoreAudio

  private static var muteAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
  }

  private static func inputDevices() -> [MicDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    let defaultInput: AudioDeviceID = read(system, kAudioHardwarePropertyDefaultInputDevice) ?? 0

    return ids.compactMap { id in
      var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
      var streamSize = UInt32(0)
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
      var mute = muteAddress
      var settable = DarwinBoolean(false)
      let hasMute = AudioObjectHasProperty(id, &mute) && AudioObjectIsPropertySettable(id, &mute, &settable) == noErr && settable.boolValue
      let muted: UInt32 = hasMute ? (read(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput) ?? 0) : 0
      return MicDevice(
        id: id,
        name: name(of: id),
        transport: read(id, kAudioDevicePropertyTransportType) ?? 0,
        muteSettable: hasMute,
        muted: muted != 0,
        isDefault: id == defaultInput
      )
    }
  }

  private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? where T: FixedWidthInteger {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = T.zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
  }

  private static func name(of id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let s = name?.takeRetainedValue() else { return "Mic" }
    return s as String
  }
}
