import Foundation

/// One player in a Sonos household, as the zone topology lists it.
public struct SonosPlayer: Equatable, Sendable {
  public var uuid: String
  /// The room it belongs to ("Office").
  public var room: String
  /// Its device description, "http://10.0.0.21:1400/xml/device_description.xml".
  public var location: String
  /// The hidden half of a stereo pair, or a home-theatre satellite: the room is controlled
  /// through its visible player.
  public var invisible: Bool

  public init(uuid: String, room: String, location: String, invisible: Bool) {
    self.uuid = uuid
    self.room = room
    self.location = location
    self.invisible = invisible
  }

  /// "http://10.0.0.21:1400", where the player's control endpoints live.
  public var baseURL: URL? {
    guard let url = URL(string: location), let scheme = url.scheme, let host = url.host else { return nil }
    return URL(string: "\(scheme)://\(host):\(url.port ?? 1400)")
  }
}

/// Pure rules for controlling one Sonos speaker on the local network through its own UPnP
/// endpoints: finding it (Bonjour, then the household's zone topology), and its RenderingControl
/// volume (0...100) and mute. Volume and mute here are the speaker's own, not its group's.
public enum SonosAudio {
  /// The Bonjour service every Sonos player advertises; its instance name is "RINCON_…@Room".
  public static let serviceType = "_sonos._tcp"
  /// The players' UPnP control port.
  public static let controlPort = 1400

  /// The room in a Bonjour instance name ("RINCON_000000000001@Office" → "Office").
  public static func room(inServiceName name: String) -> String? {
    guard let at = name.firstIndex(of: "@") else { return nil }
    let room = name[name.index(after: at)...].trimmingCharacters(in: .whitespaces)
    return room.isEmpty ? nil : room
  }

  /// Bonjour names in the order to ask them for the topology: the wanted room's own player
  /// first, then the rest as found.
  public static func askingOrder(_ names: [String], room: String) -> [String] {
    let wanted = room.trimmingCharacters(in: .whitespaces).lowercased()
    let mine = names.filter { Self.room(inServiceName: $0)?.lowercased() == wanted }
    return mine + names.filter { !mine.contains($0) }
  }

  // MARK: Finding a player without Bonjour

  /// Addresses to ask, in order, when Bonjour can't be used: the hosts of the Mac's own IPv4
  /// subnet (the /24 around it when the subnet is larger), without the Mac itself, the network
  /// and broadcast addresses. Only private (RFC 1918) networks are swept, so traffic stays on
  /// the local segment. Nil for anything else.
  public static func subnetHosts(address: String, netmask: String) -> [String]? {
    guard let a = ipv4(address), let m = ipv4(netmask), isPrivate(a) else { return nil }
    // Never sweep more than a /24.
    let mask = m | 0xFFFF_FF00 == m ? m : 0xFFFF_FF00
    let network = a & mask
    let broadcast = network | ~mask
    guard broadcast > network + 1 else { return [] }
    return (network + 1 ..< broadcast).filter { $0 != a }.map(dotted)
  }

  /// Player base URLs worth trying first: the remembered ones, then the rest of the sweep,
  /// each address once.
  public static func sweepOrder(remembered: [String], hosts: [String]) -> [String] {
    var seen = Set<String>()
    let rememberedHosts = remembered.compactMap { URL(string: $0)?.host }
    return (rememberedHosts + hosts).filter { seen.insert($0).inserted }
  }

  static func ipv4(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var v: UInt32 = 0
    for p in parts {
      guard let n = UInt8(p) else { return nil }
      v = v << 8 | UInt32(n)
    }
    return v
  }

  static func dotted(_ v: UInt32) -> String {
    [24, 16, 8, 0].map { String((v >> $0) & 0xFF) }.joined(separator: ".")
  }

  static func isPrivate(_ a: UInt32) -> Bool {
    a >> 24 == 10 || a >> 20 == 0xAC1 || a >> 16 == 0xC0A8
  }

  // MARK: Topology

  /// Players listed in a GetZoneGroupState reply (the envelope, or the decoded state itself).
  public static func players(zoneGroupState xml: String) -> [SonosPlayer] {
    var text = xml
    // The SOAP reply carries the state as escaped XML inside <ZoneGroupState>.
    if let inner = elementText("ZoneGroupState", in: xml), inner.contains("ZoneGroupMember") { text = inner }
    let reader = MemberReader()
    let parser = XMLParser(data: Data(text.utf8))
    parser.delegate = reader
    parser.parse()
    return reader.players
  }

  /// The visible player of the room called `room` (case and surrounding spaces ignored).
  public static func player(inRoom room: String, among players: [SonosPlayer]) -> SonosPlayer? {
    let wanted = room.trimmingCharacters(in: .whitespaces).lowercased()
    guard !wanted.isEmpty else { return nil }
    return players.first { !$0.invisible && $0.room.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
  }

  /// Room names, once each, sorted.
  public static func rooms(_ players: [SonosPlayer]) -> [String] {
    Array(Set(players.filter { !$0.invisible }.map(\.room))).sorted()
  }

  private final class MemberReader: NSObject, XMLParserDelegate {
    var players: [SonosPlayer] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
      guard name == "ZoneGroupMember", let uuid = a["UUID"], let room = a["ZoneName"], let location = a["Location"] else { return }
      players.append(SonosPlayer(uuid: uuid, room: room, location: location, invisible: a["Invisible"] == "1"))
    }
  }

  // MARK: Control

  public enum Action: Equatable, Sendable {
    case getZoneGroupState
    case getVolume, setVolume(Int)
    case getMute, setMute(Bool)

    var service: (path: String, urn: String) {
      switch self {
      case .getZoneGroupState: ("/ZoneGroupTopology/Control", "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
      default: ("/MediaRenderer/RenderingControl/Control", "urn:schemas-upnp-org:service:RenderingControl:1")
      }
    }

    var name: String {
      switch self {
      case .getZoneGroupState: "GetZoneGroupState"
      case .getVolume: "GetVolume"
      case .setVolume: "SetVolume"
      case .getMute: "GetMute"
      case .setMute: "SetMute"
      }
    }

    var arguments: String {
      let master = "<InstanceID>0</InstanceID><Channel>Master</Channel>"
      switch self {
      case .getZoneGroupState: return ""
      case .getVolume, .getMute: return master
      case let .setVolume(v): return master + "<DesiredVolume>\(SonosAudio.clamped(v))</DesiredVolume>"
      case let .setMute(m): return master + "<DesiredMute>\(m ? 1 : 0)</DesiredMute>"
      }
    }
  }

  /// The SOAP request for `action` on the player at `base`.
  public static func request(_ action: Action, base: URL, timeout: TimeInterval = 2) -> URLRequest {
    let (path, urn) = action.service
    var r = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    r.httpMethod = "POST"
    r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    r.setValue("\"\(urn)#\(action.name)\"", forHTTPHeaderField: "SOAPACTION")
    r.httpBody = Data(envelope(action).utf8)
    return r
  }

  public static func envelope(_ action: Action) -> String {
    let urn = action.service.urn
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
      + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
      + "<s:Body><u:\(action.name) xmlns:u=\"\(urn)\">\(action.arguments)</u:\(action.name)></s:Body></s:Envelope>"
  }

  /// CurrentVolume from a GetVolume reply.
  public static func volume(inReply xml: String) -> Int? {
    elementText("CurrentVolume", in: xml).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map(clamped)
  }

  /// CurrentMute from a GetMute reply.
  public static func mute(inReply xml: String) -> Bool? {
    switch elementText("CurrentMute", in: xml)?.trimmingCharacters(in: .whitespaces) {
    case "1": return true
    case "0": return false
    default: return nil
    }
  }

  // MARK: Levels

  /// 0...1 to the speaker's whole-percent volume.
  public static func percent(_ fraction: Double) -> Int { clamped(Int((min(max(fraction, 0), 1) * 100).rounded())) }

  public static func fraction(_ percent: Int) -> Double { Double(clamped(percent)) / 100 }

  static func clamped(_ v: Int) -> Int { min(max(v, 0), 100) }

  /// The decoded text of the first `<name>` element (any namespace prefix).
  static func elementText(_ name: String, in xml: String) -> String? {
    let reader = TextReader(name: name)
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = reader
    parser.parse()
    return reader.found
  }

  private final class TextReader: NSObject, XMLParserDelegate {
    let name: String
    var found: String?
    private var inside = false
    private var text = ""
    init(name: String) { self.name = name }

    private func local(_ element: String) -> String { element.split(separator: ":").last.map(String.init) ?? element }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
      if found == nil, local(element) == name { inside = true; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if inside { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
      if inside, local(element) == name {
        inside = false
        found = text
        parser.abortParsing()
      }
    }
  }
}
