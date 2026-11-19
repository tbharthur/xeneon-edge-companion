import AppKit
import EdgeCore
import Network

/// Volume and mute of one Sonos speaker, controlled on the local network through the speaker's
/// own UPnP endpoints (no Sonos account, no Home Assistant). The speaker is found by its room
/// name (`AppSettings.sonosRoom`), never by address: Bonjour finds the players (through the
/// system's mDNS, so nothing listens for incoming packets and the firewall has nothing to block),
/// the household's zone topology from one of them names every room, and the room's visible
/// player is the one controlled. Its own volume and mute are used, not its group's. Reads only while a card showing
/// it is on screen. A speaker that is asleep or off the network is looked for again every few
/// seconds and comes back by itself.
@MainActor
final class SonosVolumeController: ObservableObject {
  static let shared = SonosVolumeController()

  /// `denied`: macOS has not allowed the app on the local network (Privacy & Security → Local
  /// Network), so nothing can be found until it is.
  enum Status: Equatable { case waiting, ready, unavailable, denied }

  /// The room being controlled ("Office").
  @Published private(set) var room = SettingsStore.shared.settings.sonosRoom
  /// 0...1.
  @Published private(set) var level: Double?
  @Published private(set) var muted: Bool?
  @Published private(set) var status: Status = .waiting
  /// Every room the last search found, for Settings.
  @Published private(set) var rooms: [String] = []

  /// The player's control address ("http://<address>:1400"), once found.
  private var base: URL?
  private var users = 0
  private var timer: Timer?
  private var reading = false
  private var writing = false
  private var pendingLevel: Int?
  private var pendingMute: Bool?
  /// The fader's unrounded position while it is being moved.
  private var exact: Double?
  /// Readings are skipped for a moment after a change, so the fader never jumps back mid-drag.
  private var lastChange = Date.distantPast
  private var lastSearch = Date.distantPast
  private var lastTopology = Date.distantPast
  private var misses = 0

  private static let pollSeconds: TimeInterval = 3
  private static let settleSeconds: TimeInterval = 2.5
  /// How often a speaker that can't be found is looked for again.
  private static let searchSeconds: TimeInterval = 10
  /// How often the household's rooms are re-read while the speaker is found.
  private static let topologySeconds: TimeInterval = 60
  /// Missed reads in a row before the speaker counts as gone and is searched for again.
  private static let missLimit = 2

  private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 2
    c.timeoutIntervalForResource = 4
    c.waitsForConnectivity = false
    c.httpMaximumConnectionsPerHost = 1
    return URLSession(configuration: c)
  }()

  func retain() {
    users += 1
    guard users == 1 else { return }
    refresh()
    let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    t.tolerance = 1
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }

  // MARK: Actions

  func set(_ value: Double) {
    guard status == .ready else { return }
    let v = min(max(value, 0), 1)
    exact = v
    // Whole percent, the speaker's own steps, so the number shown is the one the speaker holds.
    let percent = SonosAudio.percent(v)
    let snapped = SonosAudio.fraction(percent)
    guard snapped != level else { return }
    level = snapped
    pendingLevel = percent
    lastChange = Date()
    flush()
  }

  /// Moves the fader by a finger's vertical travel. Small moves add up even when each is less
  /// than one percent.
  func drag(dy: Double, travel: Double) {
    guard status == .ready else { return }
    set(MonitorAudio.dragged(from: exact ?? level ?? 0, dy: dy, travel: travel))
  }

  /// Opens Privacy & Security → Local Network, where the app is allowed to find the speaker.
  func openLocalNetworkSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
    NSWorkspace.shared.open(url)
  }

  func toggleMute() {
    guard status == .ready else { return }
    let next = !(muted ?? false)
    muted = next
    pendingMute = next
    lastChange = Date()
    flush()
  }

  /// Sends the newest pending change once the last one is answered; changes made meanwhile
  /// collapse into one, so a drag never floods the speaker.
  private func flush() {
    guard !writing else { return }
    guard let base else {
      // No speaker to send to: a change kept for later would land long after it was meant.
      dropPending()
      return
    }
    let mute = pendingMute
    let level = pendingLevel
    guard mute != nil || level != nil else { return }
    pendingMute = nil
    pendingLevel = nil
    writing = true
    let session = session
    Task {
      var failed = false
      do {
        if let mute { _ = try await Self.call(.setMute(mute), base: base, session: session) }
        if let level { _ = try await Self.call(.setVolume(level), base: base, session: session) }
      } catch {
        failed = true
        Log.error(.dashboard, "sonos: \(error.localizedDescription)")
      }
      writing = false
      lastChange = failed ? .distantPast : Date()
      // A change made during this write goes out now, to the same speaker, or is dropped.
      if self.base != base { dropPending() }
      flush()
    }
  }

  private func dropPending() {
    pendingLevel = nil
    pendingMute = nil
    exact = nil
  }

  // MARK: Reading

  private func refresh() {
    let wanted = SettingsStore.shared.settings.sonosRoom
    if wanted != room {
      // Another room chosen in Settings: forget the old speaker and look for the new one. A
      // read or write still out for the old room is ignored when it comes back.
      room = wanted
      forgetSpeaker(status: .waiting)
      lastSearch = .distantPast
    }
    guard !reading, !writing, Date().timeIntervalSince(lastChange) > Self.settleSeconds else { return }
    if base == nil, Date().timeIntervalSince(lastSearch) < Self.searchSeconds { return }
    reading = true
    let session = session
    let known = base
    let room = room
    let checkTopology = known != nil && Date().timeIntervalSince(lastTopology) > Self.topologySeconds
    Task {
      var target = known
      if target == nil {
        lastSearch = Date()
        lastTopology = Date()
        let found = await Self.find(room: room, session: session)
        guard room == self.room else { return finishStale() }
        if !found.rooms.isEmpty { rooms = found.rooms }
        if found.denied {
          reading = false
          if status != .denied { Log.error(.dashboard, "sonos: local network access is not allowed") }
          forgetSpeaker(status: .denied)
          return
        }
        target = found.player?.baseURL
        if let player = found.player { Log.info(.dashboard, "sonos: \(room) is \(player.location)") }
      } else if checkTopology, let known {
        // Now and then, re-read the rooms: keeps Settings' list current and notices the room
        // moving to another player or address.
        lastTopology = Date()
        if let xml = try? await Self.call(.getZoneGroupState, base: known, session: session) {
          let players = SonosAudio.players(zoneGroupState: xml)
          guard room == self.room else { return finishStale() }
          if !players.isEmpty {
            rooms = SonosAudio.rooms(players)
            if SonosAudio.player(inRoom: room, among: players)?.baseURL != known { target = nil }
          }
        }
      }
      var reply: (volume: Int, muted: Bool?)?
      if let target {
        do {
          let volume = try await Self.call(.getVolume, base: target, session: session)
          let mute = try? await Self.call(.getMute, base: target, session: session)
          if let v = SonosAudio.volume(inReply: volume) { reply = (v, mute.flatMap(SonosAudio.mute(inReply:))) }
        } catch {}
      }
      apply(reply, from: target, room: room)
    }
  }

  /// A read for a room that is no longer the chosen one: drop it.
  private func finishStale() {
    reading = false
  }

  /// Clears everything learned about the speaker, including changes not yet sent.
  private func forgetSpeaker(status: Status) {
    base = nil
    level = nil
    muted = nil
    misses = 0
    dropPending()
    self.status = status
  }

  private func apply(_ reply: (volume: Int, muted: Bool?)?, from target: URL?, room fetchedFor: String) {
    reading = false
    // The room changed while this was out: it describes another speaker.
    guard fetchedFor == room else { return }
    guard let target, let reply else {
      misses += 1
      if target == nil || misses >= Self.missLimit {
        // Asleep, off the network or moved: search again (after a pause) and show it calmly.
        forgetSpeaker(status: .unavailable)
      }
      return
    }
    base = target
    misses = 0
    // A change made while the read was in flight wins over what the read saw.
    guard Date().timeIntervalSince(lastChange) > Self.settleSeconds else { return }
    level = SonosAudio.fraction(reply.volume)
    exact = nil
    if let m = reply.muted { muted = m }
    status = .ready
  }

  // MARK: Network

  enum SonosError: Error { case status(Int) }

  nonisolated static func call(_ action: SonosAudio.Action, base: URL, session: URLSession) async throws -> String {
    let (data, response) = try await session.data(for: SonosAudio.request(action, base: base))
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw SonosError.status(code) }
    return String(decoding: data, as: UTF8.self)
  }

  struct Search {
    var player: SonosPlayer?
    var rooms: [String] = []
    /// The local network is not allowed for the app.
    var denied = false
  }

  /// Finds the room's player: Bonjour lists the players, one of them (the room's own first)
  /// gives the zone topology, and that names every room with its player's address.
  nonisolated static func find(room: String, session: URLSession) async -> Search {
    let (services, denied) = await browse(timeout: 2)
    if denied { return Search(denied: true) }
    let names = SonosAudio.askingOrder(services.map(\.name), room: room)
    for name in names.prefix(3) {
      guard let endpoint = services.first(where: { $0.name == name })?.endpoint,
            let host = await resolve(endpoint, timeout: 2),
            let base = URL(string: "http://\(host):\(SonosAudio.controlPort)"),
            let xml = try? await call(.getZoneGroupState, base: base, session: session) else { continue }
      let players = SonosAudio.players(zoneGroupState: xml)
      guard !players.isEmpty else { continue }
      return Search(player: SonosAudio.player(inRoom: room, among: players), rooms: SonosAudio.rooms(players))
    }
    return Search()
  }

  nonisolated private static let networkQueue = DispatchQueue(label: "pro.seol.EdgeCompanion.sonos", qos: .utility)

  /// Settles an async wait once, from whichever of several callbacks comes first. Used only on
  /// `networkQueue`, which keeps it safe to share between those callbacks.
  private final class Once<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Never>?
    var value: Value
    init(_ initial: Value, _ continuation: CheckedContinuation<Value, Never>) {
      value = initial
      self.continuation = continuation
    }
    func finish(_ result: Value? = nil, cleanup: () -> Void) {
      guard let c = continuation else { return }
      continuation = nil
      cleanup()
      c.resume(returning: result ?? value)
    }
  }

  typealias Found = (services: [(name: String, endpoint: NWEndpoint)], denied: Bool)

  /// Cancels a browser and lets go of its handlers, which hold the browser itself: without this
  /// each search would leave a browser behind for good.
  nonisolated private static func stop(_ browser: NWBrowser) {
    browser.browseResultsChangedHandler = nil
    browser.stateUpdateHandler = nil
    browser.cancel()
  }

  nonisolated private static func stop(_ connection: NWConnection) {
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  /// The Sonos players Bonjour lists within `timeout` (it answers from the system's cache at once
  /// when it has one), or that the local network is not allowed.
  nonisolated static func browse(timeout: TimeInterval) async -> Found {
    await withCheckedContinuation { done in
      let browser = NWBrowser(for: .bonjour(type: SonosAudio.serviceType, domain: nil), using: .tcp)
      let once = Once<Found>(([], false), done)
      browser.browseResultsChangedHandler = { results, _ in
        once.value.services = results.compactMap { r in
          if case let .service(name, _, _, _) = r.endpoint { return (name, r.endpoint) }
          return nil
        }
        // Give the rest of a burst a moment to arrive.
        if !once.value.services.isEmpty { networkQueue.asyncAfter(deadline: .now() + 0.3) { once.finish { stop(browser) } } }
      }
      browser.stateUpdateHandler = { state in
        switch state {
        case let .waiting(error), let .failed(error):
          // Local Network privacy refuses the browse with PolicyDenied.
          if case let .dns(code) = error, code == -65570 {   // kDNSServiceErr_PolicyDenied
            once.value.denied = true
            once.finish { stop(browser) }
          } else if case .failed = state {
            Log.error(.dashboard, "sonos: browsing failed: \(error)")
            once.finish { stop(browser) }
          }
        default: break
        }
      }
      browser.start(queue: networkQueue)
      networkQueue.asyncAfter(deadline: .now() + timeout) { once.finish { stop(browser) } }
    }
  }

  /// A Bonjour service's IPv4 address, found by connecting to it for a moment.
  nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> String? {
    await withCheckedContinuation { done in
      let parameters = NWParameters.tcp
      (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
      let connection = NWConnection(to: endpoint, using: parameters)
      let once = Once<String?>(nil, done)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          var host: String?
          if case let .hostPort(h, _) = connection.currentPath?.remoteEndpoint, case let .ipv4(address) = h {
            // Dotted quad without the interface scope ("%en1") its description carries.
            host = [UInt8](address.rawValue).map(String.init).joined(separator: ".")
          }
          once.finish(host) { stop(connection) }
        case .failed, .cancelled: once.finish { stop(connection) }
        default: break
        }
      }
      connection.start(queue: networkQueue)
      networkQueue.asyncAfter(deadline: .now() + timeout) { once.finish { stop(connection) } }
    }
  }
}
