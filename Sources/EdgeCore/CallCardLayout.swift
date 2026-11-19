import Foundation

/// Geometry of the calls-and-sound card, from the card's content size: a row of two phone keys,
/// the recording panel under it, and the sound section (a row of equal channel strips) filling
/// the rest. Designed at 284 × 626 (a large slot on the 690-point split dashboard), where the rows
/// are 104 tall and the sound section 384. A card wider than it is tall puts the sound section
/// beside the controls instead.
public struct CallCardLayout: Equatable, Sendable {
  /// Between the two phone keys, and between the phone row and the recording panel.
  public static let rowGap: Double = 12
  /// Between the recording panel and the sound section.
  public static let soundGap: Double = 22
  /// Phone keys and the recording panel at full size.
  public static let fullRow: Double = 104
  /// The smallest the rows shrink to in a short card.
  public static let minimumRow: Double = 56

  /// The phone row and recording panel, stacked.
  public var controls: CGRect
  /// Each phone key, and the record key, is this wide.
  public var keyWidth: Double
  /// Each phone key and the recording panel are this tall.
  public var rowHeight: Double
  public var sound: CGRect
  /// The sound section sits to the right of the controls rather than under them.
  public var side: Bool

  public init(width: Double, height: Double) {
    let w = max(width, 0), h = max(height, 0)
    side = w > h * 1.2
    if side {
      let controlsWidth = floor((w - Self.soundGap) / 2)
      rowHeight = min(Self.fullRow, max(Self.minimumRow, floor((h - Self.rowGap) / 2)))
      controls = CGRect(x: 0, y: 0, width: controlsWidth, height: rowHeight * 2 + Self.rowGap)
      sound = CGRect(x: controlsWidth + Self.soundGap, y: 0, width: w - controlsWidth - Self.soundGap, height: h)
    } else {
      // Rows keep their share of the design height (104 of 592) in a shorter card.
      let share = Self.fullRow / (Self.fullRow * 2 + 384)
      rowHeight = min(Self.fullRow, max(Self.minimumRow, floor((h - Self.rowGap - Self.soundGap) * share)))
      let top = rowHeight * 2 + Self.rowGap
      controls = CGRect(x: 0, y: 0, width: w, height: top)
      sound = CGRect(x: 0, y: top + Self.soundGap, width: w, height: max(h - top - Self.soundGap, 0))
    }
    keyWidth = floor((controls.width - Self.rowGap) / 2)
  }

  /// Gap between channel strips: 12 for two, 10 from three on.
  public static func channelGap(count: Int) -> Double { count >= 3 ? 10 : 12 }

  /// Width of each of `count` equal channel strips across the sound section.
  public func channelWidth(count: Int) -> Double {
    let n = Double(max(count, 1))
    return floor((sound.width - Self.channelGap(count: count) * (n - 1)) / n)
  }

  /// Narrower than this, a strip can't hold a fader's cap and its scale.
  public static let minimumChannel: Double = 64
  /// A fader shorter than this is left out; the strip keeps its level and Mute key.
  public static let minimumFader: Double = 40

  /// In a card too narrow for every strip side by side, the mic becomes a bar across the top of
  /// the sound section and only the faders share the row.
  public func micOnTop(channels count: Int) -> Bool { channelWidth(count: count) < Self.minimumChannel }

  /// The mic bar's height when it sits above the faders: 72, less in a short card.
  public var micBar: Double { min(72, max(44, floor((sound.height - Self.channelGap(count: 2)) * 0.4))) }

  /// Width and height of each fader strip when the mic is one of `channels` strips.
  public func faderStrip(channels count: Int) -> (width: Double, height: Double) {
    if micOnTop(channels: count) {
      return (channelWidth(count: count - 1), max(sound.height - micBar - Self.channelGap(count: count - 1), 0))
    }
    return (channelWidth(count: count), sound.height)
  }

  /// Heights inside a fader strip: the name and level on top, the fader, and the Mute key at the
  /// bottom (52, rest, 72 at full size, 8 apart). In a short strip the top and the key shrink
  /// together; when the fader would be under 40 it is left out (`fader` 0) and the top and key
  /// share the height. The parts and their spacing never add up to more than the strip.
  public struct Strip: Equatable, Sendable {
    public var header: Double
    public var fader: Double
    public var muteKey: Double
    public static let spacing: Double = 8

    /// Height the parts take, spacing included.
    public var total: Double { header + muteKey + (fader > 0 ? fader + 2 * Self.spacing : Self.spacing) }
  }

  /// The strip layout for faders `height` tall (the whole sound section by default).
  public func strip(height: Double? = nil) -> Strip {
    let h = max(height ?? sound.height, 0)
    let usable = max(h - Strip.spacing * 2, 0)
    let scale = min(1, usable / 368)
    var header = max(28, floor(52 * scale))
    var key = max(36, floor(72 * scale))
    let fader = usable - header - key
    if fader >= Self.minimumFader { return Strip(header: header, fader: fader, muteKey: key) }
    // No room for a fader: the top and the key fill the strip, shrinking if they must.
    let room = max(h - Strip.spacing, 0)
    if header + key > room {
      header = floor(room * header / (header + key))
    }
    key = max(room - header, 0)
    return Strip(header: header, fader: 0, muteKey: key)
  }
}
