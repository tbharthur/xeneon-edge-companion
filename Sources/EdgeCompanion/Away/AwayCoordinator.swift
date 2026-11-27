import AppKit
import CoreGraphics
import EdgeCore
import Foundation

/// The one owner of "Arthur is away / back" for the office.
///
/// Home Assistant's office auto-off asks for a blank through `EdgeCompanion --away blank`
/// (`AwayCommand`). Unless a person used the Mac in the last minute, every display goes dark
/// (`DisplayDarkener`) and the app goes quiet: the dashboard's widgets stop (no DDC or other
/// polling), the window evictor and the Dock relocator pause. Darkness is re-applied only when a
/// display wakes, reconnects or reconfigures, plus a cheap gamma check every few seconds.
///
/// The first person input (`HumanInputWatch`, or a finger on the Edge) brings gamma back at once,
/// then brightness on the DDC queues, then lifts the quiet, which lets the Dock relocator make one
/// fresh check.
///
/// All state lives on `queue`; the published flags are for the main thread.
final class AwayCoordinator: ObservableObject {
  static let shared = AwayCoordinator()

  /// The screens are dark. Main thread.
  @Published private(set) var isAway = false
  /// Background work is paused: from a blank until brightness is back. Main thread.
  @Published private(set) var isQuiet = false
  /// Called on the main thread after `isAway` or `isQuiet` changes.
  var onChange: (() -> Void)?

  let input = HumanInputWatch()

  private let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.away", qos: .userInitiated)
  private var state = AwayState()
  private var controllers: [String: DDCController] = [:]
  private var lastRequestID: String?
  private var heartbeat: DispatchSourceTimer?
  private var directoryWatch: DispatchSourceFileSystemObject?
  private var awakeScreens = Set<CGDirectDisplayID>()
  private var reassertGeneration = 0
  private var lastReassertLog = Date.distantPast
  private var restoreRetries = 0
  private var observers: [NSObjectProtocol] = []

  /// Read from the input threads without waiting for `queue`.
  private let flagLock = NSLock()
  private var darkFlag = false
  private var wakingFlag = false

  private static let tick: TimeInterval = 5
  /// The longest the quiet waits for brightness before lifting anyway.
  private static let restoreCap: TimeInterval = 8

  // MARK: - Lifecycle (main thread)

  func start() {
    input.onPersonInput = { [weak self] kind in _ = self?.personInput(kind) }
    input.start()
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback(awayReconfigurationCallback, ctx)
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
        self?.displaysChanged(note.name.rawValue.replacingOccurrences(of: "NSWorkspace", with: ""))
      })
    }
    queue.async { self.boot() }
  }

  /// Input Monitoring may have just been granted.
  func permissionsChanged() {
    if !input.isRunning { input.start() }
  }

  /// App quitting: put the screens back before the process goes (gamma would return on its own;
  /// DDC brightness would not). Waits a few seconds at most.
  func restoreBeforeQuit() {
    let done = DispatchSemaphore(value: 0)
    queue.async {
      guard self.state.needsRestore else { done.signal(); return }
      self.unblank(reason: "app quitting") { done.signal() }
    }
    _ = done.wait(timeout: .now() + 4)
  }

  /// A finger on the Edge (HID thread). True while the screens are dark: that touch only wakes them.
  func fingerDown() -> Bool {
    input.notePersonInput()
    return personInput("Edge touch")
  }

  // MARK: - Input (any thread; never blocks)

  private func personInput(_ kind: String) -> Bool {
    flagLock.lock()
    let dark = darkFlag
    let wake = dark && !wakingFlag
    if wake { wakingFlag = true }
    flagLock.unlock()
    if wake {
      queue.async {
        // Another path (the unblank command, a second input thread) may have woken first.
        guard self.state.blanked else { return self.setDark(false) }
        self.unblank(reason: kind) {}
      }
    }
    return dark
  }

  private func setDark(_ dark: Bool) {
    flagLock.lock()
    darkFlag = dark
    wakingFlag = false
    flagLock.unlock()
  }

  // MARK: - Queue

  private func boot() {
    AwayFiles.ensureDirectory()
    if let data = try? Data(contentsOf: AwayFiles.state), let saved = try? JSONDecoder().decode(AwayState.self, from: data) {
      state = saved
    }
    lastRequestID = AwayFiles.read(AwayFiles.request).flatMap(AwayMessage.parseRequest)?.id
    if state.needsRestore {
      Log.info(.away, "startup: restoring screens left dark by an earlier run")
      unblank(reason: "startup") {}
    }
    writeHeartbeat()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .seconds(1))
    timer.setEventHandler { [weak self] in self?.tickOnQueue() }
    timer.resume()
    heartbeat = timer
    watchRequests()
    Log.info(.away, "ready; requests in \(AwayFiles.directory.path)")
  }

  private func watchRequests() {
    let fd = open(AwayFiles.directory.path, O_EVTONLY)
    guard fd >= 0 else {
      Log.error(.away, "cannot watch \(AwayFiles.directory.path)")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
    source.setEventHandler { [weak self] in self?.checkRequest() }
    source.setCancelHandler { close(fd) }
    source.resume()
    directoryWatch = source
    checkRequest()
  }

  private func checkRequest() {
    guard let text = AwayFiles.read(AwayFiles.request), let request = AwayMessage.parseRequest(text),
          request.id != lastRequestID else { return }
    lastRequestID = request.id
    switch request.command {
    case .blank:
      let idle = input.secondsSincePersonInput
      let outcome = AwayRequest.decideBlank(isAway: state.blanked, inputWatchRunning: input.isRunning, secondsSinceInput: idle)
      switch outcome {
      case .blanked:
        blank(idle: idle)
        respond(request.id, outcome)
        dimAwakeMonitors()
      case .ignoredActive:
        Log.info(.away, String(format: "blank request ignored: input %.0fs ago", idle))
        respond(request.id, outcome, String(format: "input %.0fs ago", idle))
      case .unavailable:
        Log.error(.away, "blank request refused: the input watch is off, so nothing could wake the screens")
        respond(request.id, outcome, "input watch is off (Input Monitoring?)")
      default:
        respond(request.id, outcome)
      }
    case .unblank:
      if state.needsRestore {
        // Gamma is back when unblank returns; brightness follows on the DDC queues.
        unblank(reason: "unblank command") {}
        respond(request.id, .restored)
      } else {
        respond(request.id, .notAway)
      }
    }
  }

  private func respond(_ id: String, _ outcome: AwayRequest.Outcome, _ detail: String = "") {
    AwayFiles.writeAtomically(AwayMessage.response(id: id, outcome: outcome, detail: detail), to: AwayFiles.response)
  }

  private func blank(idle: TimeInterval) {
    Log.info(.away, String(format: "blanking (person input %.0fs ago)", idle))
    state.blanked = true
    save()
    setDark(true)
    DisplayDarkener.zeroGamma()
    awakeScreens = Set(DisplayDarkener.screens().filter { !$0.isAsleep }.map(\.id))
    publish(away: true, quiet: true)
  }

  /// Gamma back at once, then brightness off the main thread, then the quiet lifts.
  private func unblank(reason: String, completion: @escaping () -> Void) {
    if state.blanked {
      DisplayDarkener.restoreGamma()
      state.blanked = false
      save()
      Log.info(.away, "back: \(reason); gamma restored")
    }
    setDark(false)
    publish(away: false, quiet: true)
    restoreBrightness(reason: reason) {
      self.publish(away: false, quiet: false)
      completion()
    }
  }

  private func restoreBrightness(reason: String, completion: @escaping () -> Void) {
    let saved = state.savedLuminance
    guard !saved.isEmpty else { completion(); return }
    let screens = DisplayDarkener.screens()
    let group = DispatchGroup()
    for (uuid, value) in saved {
      guard let location = screens.first(where: { $0.uuid == uuid })?.location else {
        Log.info(.away, "restore of \(uuid) to \(value) waits: display not connected")
        continue
      }
      let ddc = controller(for: location)
      group.enter()
      ddc.queue.async {
        let ok = DisplayDarkener.setBrightness(ddc, value)
        self.queue.async {
          if ok, !self.state.blanked {
            self.state.savedLuminance[uuid] = nil
            Log.info(.away, "restored \(uuid) brightness to \(value)")
          } else if !ok {
            Log.error(.away, "restore of \(uuid) to \(value) failed; will retry")
          }
          group.leave()
        }
      }
    }
    var finished = false
    let finish = {
      guard !finished else { return }
      finished = true
      self.save()
      completion()
    }
    group.notify(queue: queue) {
      finish()
      self.scheduleRestoreRetry()
    }
    queue.asyncAfter(deadline: .now() + Self.restoreCap) {
      if !finished { Log.info(.away, "brightness restore still running after \(Int(Self.restoreCap)) s; resuming anyway") }
      finish()
    }
  }

  private func scheduleRestoreRetry() {
    guard !state.blanked, !state.savedLuminance.isEmpty else {
      restoreRetries = 0
      return
    }
    guard restoreRetries < 3 else {
      Log.error(.away, "brightness restore gave up for now; next start or blank episode retries")
      restoreRetries = 0
      return
    }
    restoreRetries += 1
    queue.asyncAfter(deadline: .now() + 30) {
      guard !self.state.blanked, !self.state.savedLuminance.isEmpty else { return }
      self.restoreBrightness(reason: "retry") {}
    }
  }

  /// DDC brightness 0 on awake external monitors. A monitor already dimmed this episode only gets
  /// the 0 written again (no read); an asleep one waits until it wakes, since DDC can wake it.
  private func dimAwakeMonitors() {
    guard state.blanked else { return }
    let ddcLocations = DisplayDarkener.ddcLocations()
    for screen in DisplayDarkener.screens() where !screen.isAsleep {
      guard let location = screen.location, ddcLocations.contains(location) else { continue }
      let ddc = controller(for: location)
      let uuid = screen.uuid
      if state.savedLuminance[uuid] != nil {
        ddc.queue.async { try? ddc.writeBrightness(0) }
        continue
      }
      ddc.queue.async {
        let current = DisplayDarkener.readBrightness(ddc)
        // Decide on the away queue: a person may have come back while the bus was busy.
        let restoreTo: Int? = self.queue.sync {
          guard self.state.blanked, self.state.savedLuminance[uuid] == nil else { return nil }
          let plan = AwayBrightness.plan(current: current, lastGood: self.state.lastGood[uuid])
          if let good = plan.lastGood { self.state.lastGood[uuid] = good }
          guard let restoreTo = plan.restoreTo else {
            Log.info(.away, "dim skipped for \(uuid): no brightness reading and no known level")
            return nil
          }
          self.state.savedLuminance[uuid] = restoreTo
          self.save()
          return restoreTo
        }
        guard let restoreTo else { return }
        let ok = DisplayDarkener.setBrightness(ddc, 0)
        Log.info(.away, ok ? "dimmed \(uuid) from \(current.map(String.init) ?? "unknown"); will restore to \(restoreTo)" : "dim failed for \(uuid)")
      }
    }
  }

  private func controller(for location: String) -> DDCController {
    if let c = controllers[location] { return c }
    let c = DDCController(display: .located(location))
    controllers[location] = c
    return c
  }

  // MARK: - Display changes

  /// A display was added, woke, changed mode, or the system woke. Main thread or a callback.
  fileprivate func displaysChanged(_ why: String) {
    queue.async {
      self.controllers.removeAll()
      guard self.state.blanked else { return }
      self.reassert(why)
    }
  }

  /// Re-darkens now and again shortly after, since a wake's ColorSync reload can land late; DDC
  /// waits for the later pass, when a freshly woken monitor answers.
  private func reassert(_ why: String) {
    reassertGeneration += 1
    let generation = reassertGeneration
    // Reconfiguration arrives in bursts (one callback per display and change); log the first.
    if Date().timeIntervalSince(lastReassertLog) > 3 {
      Log.info(.away, "\(why) while away; keeping the screens dark")
    }
    lastReassertLog = Date()
    DisplayDarkener.zeroGamma()
    for (delay, withDDC) in [(0.3, false), (1.5, true), (4.0, false)] {
      queue.asyncAfter(deadline: .now() + delay) {
        guard self.state.blanked, generation == self.reassertGeneration else { return }
        DisplayDarkener.zeroGamma()
        if withDDC {
          self.awakeScreens = Set(DisplayDarkener.screens().filter { !$0.isAsleep }.map(\.id))
          self.dimAwakeMonitors()
        }
      }
    }
  }

  // MARK: - Heartbeat and safety check

  private func tickOnQueue() {
    writeHeartbeat()
    guard state.blanked else { return }
    // Cheap: two small WindowServer queries per display, nothing listed, nothing spawned.
    for screen in DisplayDarkener.screens() where !screen.isAsleep {
      if !awakeScreens.contains(screen.id) {
        awakeScreens.insert(screen.id)
        reassert("display \(screen.id) woke")
        return
      }
      if !DisplayDarkener.gammaIsDark(screen.id) {
        reassert("display \(screen.id) gamma was reset")
        return
      }
    }
    awakeScreens = Set(DisplayDarkener.screens().filter { !$0.isAsleep }.map(\.id))
  }

  private func writeHeartbeat() {
    let line = String(format: "pid %d · away %@ · input watch %@ · person input %.0fs ago · saved %@\n",
                      getpid(), state.blanked ? "yes" : "no", input.isRunning ? "on" : "off",
                      input.secondsSincePersonInput, state.savedLuminance.description)
    // In place (no rename), so the directory watch doesn't fire every tick.
    try? Data(line.utf8).write(to: AwayFiles.heartbeat)
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(state) else { return }
    AwayFiles.writeAtomically(String(decoding: data, as: UTF8.self), to: AwayFiles.state)
  }

  private func publish(away: Bool, quiet: Bool) {
    DispatchQueue.main.async {
      guard self.isAway != away || self.isQuiet != quiet else { return }
      self.isAway = away
      self.isQuiet = quiet
      self.onChange?()
    }
  }
}

private func awayReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
  // Never act inside the WindowServer transaction; the coordinator re-applies asynchronously.
  guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
  Unmanaged<AwayCoordinator>.fromOpaque(userInfo).takeUnretainedValue().displaysChanged("display \(display) reconfigured")
}
