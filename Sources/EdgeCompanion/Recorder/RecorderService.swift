import Combine
import EdgeCore
import Foundation

/// Watches the local meeting recorder (capture PID/ready files, the pipeline's status file and its
/// log) while the recorder widget is on screen, and starts or stops a recording through the same
/// script the Poly speakerphone button uses.
@MainActor
final class RecorderService: ObservableObject {
  static let shared = RecorderService()

  @Published private(set) var phase: RecorderPhase = .idle(last: nil)
  @Published private(set) var now = Date()
  /// Set between tapping Record and the pipeline reporting it is starting.
  @Published private(set) var requested: Request?
  /// The last start/stop failure, shown until the next action.
  @Published private(set) var error: String?

  enum Request { case start, stop }

  private static let pidFile = "/tmp/record-audio.pid"
  private static let readyFile = "/tmp/record-audio.ready"
  private static var statusFile: String { NSHomeDirectory() + "/Library/Application Support/Meeting Recorder/status.json" }
  private static var logFile: String { NSHomeDirectory() + "/.devboard/logs/meeting-recorder.log" }

  private var users = 0
  private var timer: Timer?
  private var requestedAt = Date.distantPast

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

  // MARK: Reading

  private func refresh() {
    now = Date()
    let pid = Self.readPID(Self.pidFile)
    let alive = pid.map { kill($0, 0) == 0 } ?? false
    let readyPID = Self.readPID(Self.readyFile)
    let ready = alive && readyPID == pid
    let readySince = ready ? Self.modified(Self.readyFile) : nil
    let status = FileManager.default.contents(atPath: Self.statusFile).flatMap(RecorderStatusFile.decode)
    let tail = status?.phase == "transcribing" ? Self.tail(Self.logFile, bytes: 64 * 1024) : nil
    let next = RecorderModel.phase(status: status, captureAlive: alive, captureReady: ready, readySince: readySince, logTail: tail, now: now)
    if next != phase { phase = next }
    // Clear a pending request once the pipeline shows it, or after a timeout.
    if let r = requested {
      let done = switch (r, next) {
      case (.start, .idle): false
      case (.start, _): true
      case (.stop, .recording), (.stop, .starting): false
      case (.stop, _): true
      }
      if done || now.timeIntervalSince(requestedAt) > 150 { requested = nil }
    }
  }

  private static func readPID(_ path: String) -> pid_t? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return s.split(whereSeparator: \.isNewline).first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
  }

  private static func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  private static func tail(_ path: String, bytes: UInt64) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    guard let size = try? h.seekToEnd() else { return nil }
    try? h.seek(toOffset: size > bytes ? size - bytes : 0)
    guard let data = try? h.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Actions

  func start() {
    guard requested == nil else { return }
    let s = SettingsStore.shared.settings
    var env = ProcessInfo.processInfo.environment
    if !s.recorderOutputDevice.isEmpty { env["RECORD_AUDIO_FORCE_OUTPUT_DEVICE"] = s.recorderOutputDevice }
    run(.start, arguments: ["start", "--name", s.recorderName.isEmpty ? "local-meeting" : s.recorderName], environment: env)
  }

  func stop() {
    guard requested == nil else { return }
    run(.stop, arguments: ["stop"], environment: ProcessInfo.processInfo.environment)
  }

  private func run(_ request: Request, arguments: [String], environment: [String: String]) {
    let script = (SettingsStore.shared.settings.recorderScript as NSString).expandingTildeInPath
    guard FileManager.default.isExecutableFile(atPath: script) else {
      error = tr("녹음 스크립트를 찾을 수 없어요", "Recorder script not found")
      return
    }
    error = nil
    requested = request
    requestedAt = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: script)
    p.arguments = arguments
    p.environment = environment
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = FileHandle.nullDevice
    p.terminationHandler = { [weak self] proc in
      let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: \.isNewline).last.map(String.init)
      let failed = proc.terminationStatus != 0
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          if failed {
            Log.error(.dashboard, "recorder \(arguments.first ?? "") failed: \(message ?? "status \(proc.terminationStatus)")")
            self.error = message ?? tr("녹음기 오류", "Recorder error")
            self.requested = nil
          }
          self.refresh()
        }
      }
    }
    do {
      try p.run()
      Log.info(.dashboard, "recorder \(arguments.first ?? "") requested")
    } catch {
      self.error = error.localizedDescription
      requested = nil
    }
  }
}
