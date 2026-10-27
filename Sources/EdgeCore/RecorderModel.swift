import Foundation

/// The meeting recorder pipeline's status file (`status.json`, version 1), written at each stage.
public struct RecorderStatusFile: Decodable, Equatable, Sendable {
  public var phase: String
  public var result: String?
  public var detail: String?
  public var name: String?
  public var startedAt: String?
  public var stoppedAt: String?
  public var audioSeconds: Double?
  public var updatedAt: String?

  public static func decode(_ data: Data) -> RecorderStatusFile? {
    try? JSONDecoder().decode(RecorderStatusFile.self, from: data)
  }
}

/// How the last finished run ended.
public struct RecorderLastRun: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable { case sent, undelivered, empty, failed, startFailed, other(String) }
  public var outcome: Outcome
  public var detail: String?
  public var name: String?
  public var endedAt: Date?
  public var audioSeconds: Double?
}

public enum RecorderPhase: Equatable, Sendable {
  case idle(last: RecorderLastRun?)
  case starting
  case recording(since: Date?)
  /// `progress` is 0...1 from the transcript's latest timestamp, nil until the first segment.
  case transcribing(progress: Double?, audioSeconds: Double?)
  case sending
}

public enum RecorderModel {
  /// A "recording" status with no live capture is the launch gap; older than this it is stale.
  public static let launchGrace: TimeInterval = 150

  /// - Parameters:
  ///   - captureAlive: the capture process in the PID file is running.
  ///   - captureReady: the ready file names that process (audio callbacks have started).
  ///   - readySince: when the ready file was written.
  ///   - logTail: the end of the pipeline log, for transcription progress.
  public static func phase(status: RecorderStatusFile?, captureAlive: Bool, captureReady: Bool, readySince: Date?, logTail: String?, now: Date) -> RecorderPhase {
    if captureAlive {
      return captureReady ? .recording(since: readySince ?? QuotaModel.parseDate(status?.startedAt)) : .starting
    }
    guard let status else { return .idle(last: nil) }
    switch status.phase {
    case "recording":
      let updated = QuotaModel.parseDate(status.updatedAt) ?? .distantPast
      return now.timeIntervalSince(updated) < launchGrace ? .starting : .idle(last: nil)
    case "transcribing":
      let progress = transcriptionProgress(logTail: logTail, audioSeconds: status.audioSeconds)
      return .transcribing(progress: progress, audioSeconds: status.audioSeconds)
    case "sending":
      return .sending
    default:
      return .idle(last: lastRun(status))
    }
  }

  static func lastRun(_ s: RecorderStatusFile) -> RecorderLastRun {
    let outcome: RecorderLastRun.Outcome = switch s.result {
    case "sent": .sent
    case "undelivered": .undelivered
    case "empty": .empty
    case "failed": .failed
    case "start_failed": .startFailed
    default: .other(s.result ?? "")
    }
    let ended = QuotaModel.parseDate(s.updatedAt) ?? QuotaModel.parseDate(s.stoppedAt)
    return RecorderLastRun(outcome: outcome, detail: s.detail, name: s.name, endedAt: ended, audioSeconds: s.audioSeconds)
  }

  /// Progress from whisper's printed segments (`[00:01:02.000 --> 00:01:04.500]`) after the
  /// current run's "Transcribing:" line. Nil if this run has printed no segment yet, including the
  /// moment before it logs its own marker, when the newest lines still belong to the previous run.
  /// Completion is reported by the status file moving on, not from the log.
  public static func transcriptionProgress(logTail: String?, audioSeconds: Double?) -> Double? {
    guard let tail = logTail, let total = audioSeconds, total > 0 else { return nil }
    let started = tail.range(of: "Transcribing: ", options: .backwards)
    let saved = tail.range(of: "Transcript saved to:", options: .backwards)
    let region: Substring
    if let started {
      if let saved, saved.lowerBound > started.lowerBound { return nil }
      region = tail[started.upperBound...]
    } else {
      // The marker scrolled out of the tail; segments belong to this run unless an older run ended here.
      if saved != nil { return nil }
      region = tail[...]
    }
    guard let end = lastSegmentEnd(region) else { return nil }
    return min(max(end / total, 0), 1)
  }

  static func lastSegmentEnd(_ text: Substring) -> Double? {
    var search = text.endIndex
    while let arrow = text.range(of: " --> ", options: .backwards, range: text.startIndex ..< search) {
      search = arrow.lowerBound
      let after = text[arrow.upperBound...].prefix(12)
      guard after.count == 12, text[after.endIndex...].first == "]" else { continue }
      let parts = after.split(separator: ":")
      guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { continue }
      return h * 3600 + m * 60 + s
    }
    return nil
  }
}
