import Foundation

public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
  /// `network` also pages to disk activity; `system` pages to top processes.
  case clock, cpu, gpu, memory, network, sensors, battery, launcher, system, aiUsage, timer, volume
  /// Keep-awake durations and a sleep button.
  case sleep
  /// Discord voice: on a call or not, and with a linked app, who is in it.
  case discord
  /// A web page (address in `AppSettings.webURL`).
  case web
  /// A photo, GIF or video on loop (file in `AppSettings.mediaItems`); any number may be placed.
  case media
  /// Every account from a local multi-account usage feed (`AppSettings.quotaFeedURL`).
  case quotas
  /// Calls and sound in one card: iPhone call keys, the local meeting recorder, mic mute, and
  /// faders for the desk monitor's speakers (DDC/CI) and a Sonos speaker.
  case callSound
  /// An empty cell for spacing; any number of them may be placed.
  case spacer
  public var id: String { rawValue }

  public var allowsMultiple: Bool { self == .spacer || self == .media }

  /// Kinds from earlier versions, folded into the current ones (nil: dropped).
  public static func migrating(_ raw: String) -> WidgetKind? {
    if let kind = WidgetKind(rawValue: raw) { return kind }
    switch raw {
    case "disk": return .network
    case "processes": return .system
    case "claudeUsage", "codexUsage": return .aiUsage
    case _ where mergedIntoCallSound.contains(raw): return .callSound
    default: return nil   // bluetooth: shown in the power widget now
    }
  }

  /// The call recorder and monitor volume cards, now one card that takes over all their cells.
  public static let mergedIntoCallSound: Set<String> = ["recorder", "monitorVolume"]
}

/// One widget on a dashboard page.
public struct WidgetSlot: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var kind: WidgetKind
  public var size: WidgetSize = .small

  public init(id: UUID = UUID(), kind: WidgetKind, size: WidgetSize = .small) {
    self.id = id
    self.kind = kind
    self.size = size
  }

  private enum CodingKeys: String, CodingKey { case id, kind, size }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try c.decode(String.self, forKey: .kind)
    guard let kind = WidgetKind.migrating(raw) else {
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "retired widget \(raw)")
    }
    self.kind = kind
    id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    size = (try? c.decodeIfPresent(WidgetSize.self, forKey: .size)) ?? .small
  }
}

/// A swipeable dashboard page; widgets pack into its two rows in order.
public struct DashboardPage: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var slots: [WidgetSlot]

  public init(id: UUID = UUID(), slots: [WidgetSlot]) {
    self.id = id
    self.slots = slots
  }

  private enum CodingKeys: String, CodingKey { case id, slots }

  /// One saved slot, read without failing the page: the slot if its kind still exists, and the
  /// kind it was saved under.
  private struct LenientSlot: Decodable {
    let slot: WidgetSlot?
    let savedKind: String?
    private enum Keys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
      slot = try? WidgetSlot(from: decoder)
      savedKind = try? decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
    }
  }

  /// Skips retired widget kinds, unreadable slots and duplicates instead of failing the whole
  /// layout. The recorder and monitor volume cards became one: it sits where the first of them
  /// was and covers the cells of both (two tall cards side by side make one large).
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    let saved = (try? c.decode([LenientSlot].self, forKey: .slots)) ?? []
    var decoded = saved.compactMap(\.slot)
    let mergedSizes = saved.compactMap { s -> WidgetSize? in
      guard let kind = s.savedKind, WidgetKind.mergedIntoCallSound.contains(kind) else { return nil }
      return s.slot?.size
    }
    if mergedSizes.count > 1, let first = decoded.firstIndex(where: { $0.kind == .callSound }),
       let covering = WidgetSize.covering(mergedSizes) {
      decoded[first].size = covering
    }
    var seen = Set<WidgetKind>()
    slots = decoded.filter { $0.kind.allowsMultiple || seen.insert($0.kind).inserted }
  }

  /// Pages as loaded: retired kinds can map onto a widget that already exists (e.g. processes →
  /// system), so the first occurrence across all pages is kept, then pages left empty are dropped.
  public static func normalized(_ pages: [DashboardPage]) -> [DashboardPage] {
    var seen = Set<WidgetKind>()
    return pages.map { page in
      var p = page
      p.slots = page.slots.filter { $0.kind.allowsMultiple || seen.insert($0.kind).inserted }
      return p
    }.filter { !$0.slots.isEmpty }
  }

  public static let defaultPages: [DashboardPage] = [
    DashboardPage(slots: [
      WidgetSlot(kind: .clock, size: .tall),
      WidgetSlot(kind: .network), WidgetSlot(kind: .cpu),
      WidgetSlot(kind: .sensors), WidgetSlot(kind: .gpu),
      WidgetSlot(kind: .battery), WidgetSlot(kind: .memory),
      WidgetSlot(kind: .system), WidgetSlot(kind: .aiUsage),
    ]),
    DashboardPage(slots: [
      WidgetSlot(kind: .launcher, size: .large),
    ]),
  ]
}
