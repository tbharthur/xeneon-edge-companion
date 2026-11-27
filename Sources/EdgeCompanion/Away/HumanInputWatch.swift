import CoreGraphics
import Darwin
import EdgeCore
import Foundation

/// Notices a person's input: a listen-only session event tap over every input kind (moves,
/// clicks, keys, scrolls, gestures), classified by `HumanInput` from the event's source process.
/// Hardware input comes from process 0; Computer Use, the Dock relocator and other automation post
/// from their own process and never count.
///
/// The tap runs on its own thread and only reads event fields, takes a lock and queues work; it
/// makes no WindowServer calls, so a busy WindowServer cannot make macOS disable it. A listen-only
/// tap is not in the event path, so it never delays anyone's input either.
final class HumanInputWatch {
  /// Called on the tap thread for each person event. Must return quickly and never block.
  var onPersonInput: ((String) -> Void)?

  private let lock = NSLock()
  private var lastPersonInput: TimeInterval
  private var running = false
  private var tap: CFMachPort?
  private var thread: Thread?
  private let ownPID = getpid()
  /// Source process id -> name, for posted events. Tap thread only.
  private var names: [Int32: String] = [:]
  private var namesSince: TimeInterval = 0

  init() {
    // Until the tap has seen something, assume someone was here at launch.
    lastPersonInput = ProcessInfo.processInfo.systemUptime
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  var secondsSincePersonInput: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return ProcessInfo.processInfo.systemUptime - lastPersonInput
  }

  /// Notes input seen another way (an Edge touch read straight from its HID device).
  func notePersonInput() {
    lock.lock()
    lastPersonInput = ProcessInfo.processInfo.systemUptime
    lock.unlock()
  }

  /// Starts the tap if it is not running. Returns false without Input Monitoring.
  @discardableResult
  func start() -> Bool {
    if isRunning { return true }
    let ready = DispatchSemaphore(value: 0)
    let t = Thread { [weak self] in
      guard let self else { ready.signal(); return }
      let ok = self.installTap()
      ready.signal()
      if ok { CFRunLoopRun() }
    }
    t.name = "EdgeCompanion.HumanInputWatch"
    t.qualityOfService = .userInteractive
    t.start()
    ready.wait()
    lock.lock()
    let ok = tap != nil
    running = ok
    if ok { thread = t }
    lock.unlock()
    if ok { Log.info(.away, "input watch on") } else { Log.error(.away, "input watch unavailable (Input Monitoring not granted?)") }
    return ok
  }

  private func installTap() -> Bool {
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMask(HumanInput.personMask), callback: { _, type, event, ctx in
      if let ctx { Unmanaged<HumanInputWatch>.fromOpaque(ctx).takeUnretainedValue().handle(type: type, event: event) }
      return Unmanaged.passUnretained(event)
    }, userInfo: ctx) else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    lock.lock()
    tap = port
    lock.unlock()
    return true
  }

  // MARK: - Tap thread

  private func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lock.lock()
      let port = tap
      lock.unlock()
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      Log.info(.away, "input watch re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
      return
    }
    let moved = event.getIntegerValueField(.mouseEventDeltaX) != 0 || event.getIntegerValueField(.mouseEventDeltaY) != 0
    let verdict = HumanInput.classify(
      type: type.rawValue,
      sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
      userData: event.getIntegerValueField(.eventSourceUserData),
      ownPID: ownPID,
      moved: moved,
      processName: processName)
    guard case let .person(kind)? = verdict else { return }
    lock.lock()
    lastPersonInput = ProcessInfo.processInfo.systemUptime
    lock.unlock()
    onPersonInput?(kind)
  }

  /// A kernel lookup, cached for a minute (process ids get reused); never a WindowServer call.
  private func processName(_ pid: Int32) -> String? {
    let now = ProcessInfo.processInfo.systemUptime
    if now - namesSince > 60 || names.count > 256 {
      names.removeAll()
      namesSince = now
    }
    if let name = names[pid] { return name }
    var buffer = [CChar](repeating: 0, count: 256)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    let name = length > 0 ? String(cString: buffer) : ""
    names[pid] = name
    return name
  }
}
