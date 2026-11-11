import Foundation

/// MCCS audio controls on an external monitor's built-in speakers or headphone jack.
/// Only these two codes are written to a monitor other than the Edge.
public enum MonitorAudioVCP: UInt8, CaseIterable, Sendable {
  case volume = 0x62
  case mute = 0x8D
}

/// Pure rules for the monitor volume fader: value scaling, mute encoding and finger travel.
public enum MonitorAudio {
  /// MCCS 0x8D: 1 is muted, 2 is unmuted. Anything else is unknown.
  public static func isMuted(_ raw: UInt16) -> Bool? {
    switch raw {
    case 1: return true
    case 2: return false
    default: return nil
    }
  }

  public static func muteValue(_ muted: Bool) -> UInt16 { muted ? 1 : 2 }

  /// A reading as 0...1. A monitor that reports no maximum is treated as 0...100.
  public static func fraction(current: UInt16, maximum: UInt16) -> Double {
    let top = Double(maximum == 0 ? 100 : maximum)
    return min(max(Double(current) / top, 0), 1)
  }

  /// 0...1 back to the monitor's own scale, rounded to a whole step.
  public static func raw(_ fraction: Double, maximum: UInt16) -> UInt16 {
    let top = Double(maximum == 0 ? 100 : maximum)
    return UInt16((min(max(fraction, 0), 1) * top).rounded())
  }

  /// Moves the fader by a vertical finger travel. `travel` is the track's length in points;
  /// a finger moving up (negative `dy`, top-left coordinates) raises the level.
  public static func dragged(from level: Double, dy: Double, travel: Double) -> Double {
    guard travel > 0 else { return level }
    return min(max(level - dy / travel, 0), 1)
  }

  /// Where a tap on the track puts the fader: the top of the track is 1, the bottom 0.
  public static func level(atY y: Double, top: Double, travel: Double) -> Double {
    guard travel > 0 else { return 0 }
    return min(max(1 - (y - top) / travel, 0), 1)
  }
}
