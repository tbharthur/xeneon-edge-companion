import Combine
import EdgeCore
import Foundation

/// Settings that belong to one physical panel, keyed by its real serial number.
struct EdgeProfile: Codable, Equatable {
  var whiteBalance: WhiteBalance = .tunedD65
  /// Gains read from the panel the first time we saw it, so "restore" can put them back.
  var originalWhiteBalance: WhiteBalance?
  var originalColorPreset: UInt16?
  var applyColorOnConnect = true
  var touchCalibration: TouchCalibration = .identity
}

enum TerminalSide: String, Codable, CaseIterable {
  case left, right
}

struct LauncherItem: Codable, Equatable, Identifiable {
  var id = UUID()
  var title: String
  /// Bundle identifier, absolute app path, URL ("https://…"), or "shell:<command>".
  var target: String
}

/// The file shown by one media widget.
struct MediaItem: Codable, Equatable {
  /// Name of the copy in `MediaLibrary.folder`.
  var file: String
  /// Name of the file the user picked, for display.
  var originalName: String
  /// Fill the card (cropping) rather than fit inside it.
  var fill = true
}

struct AppSettings: Codable, Equatable {
  var language: AppLanguage = .system

  // Touch
  var touchEnabled = true
  var longPressRightClick = true
  var horizontalMoveDrags = false
  var scrollSpeed = 1.0
  var momentumScrolling = true
  var restoreCursorAfterTouch = true

  // Edge as a dedicated surface
  var dashboardEnabled = true
  /// The dashboard covers only one end of the Edge; the rest stays a regular display.
  var splitEnabled = false
  var splitSide: SplitSide = .right
  /// Dashboard length along the Edge's long side in split mode, in points.
  var splitLength = 1280.0
  var mouseFenceEnabled = true
  /// Entering the Edge with Option held lets the pointer roam it until it leaves.
  var fenceBypassWithOption = true
  /// Keep the Dock off the Edge.
  var dockLockEnabled = true
  var evictWindows = true
  var ensureNativeResolution = true

  // Dashboard
  var terminalEnabled = true
  var terminalSide: TerminalSide = .left
  var terminalWidth = 1120.0
  var terminalFontSize = 14.0
  var terminalUseTmux = true
  var pages: [DashboardPage] = DashboardPage.defaultPages
  var launcherItems: [LauncherItem] = [
    LauncherItem(title: "Finder", target: "com.apple.finder"),
    LauncherItem(title: "Safari", target: "com.apple.Safari"),
    LauncherItem(title: "Activity Monitor", target: "com.apple.ActivityMonitor"),
    LauncherItem(title: "System Settings", target: "com.apple.systempreferences"),
  ]
  /// Page shown by the web widget; a bare host gets https://.
  var webURL = ""
  var webZoom = 1.0
  /// The user's own Discord application for the RPC link; its secret is in the keychain.
  var discordClientID = ""
  /// Multi-account usage feed read by the account quotas widget.
  var quotaFeedURL = "http://127.0.0.1:8797/v1/usage"
  /// Recorder widget: the pipeline script and the recording name. The output device is whatever the Mac uses by default.
  var recorderScript = "~/Dev/assistant/tools/meeting-recorder/record.sh"
  var recorderName = "local-meeting"
  /// The Sonos room (as named in the Sonos app) whose speaker the calls-and-sound card controls.
  var sonosRoom = "Office"
  /// The Sonos household's player addresses as last seen ("http://<address>:1400"), learned at run
  /// time so the next search can ask one of them first.
  var sonosPlayers: [String] = []
  /// Show each Mac notification banner across the dashboard for a moment.
  var notificationsEnabled = false
  /// Media widget files by slot id (uuidString).
  var mediaItems: [String: MediaItem] = [:]

  var profiles: [String: EdgeProfile] = [:]

  init() {}

  // Decode leniently so adding a field never wipes existing settings.
  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
    language = v(.language, language)
    touchEnabled = v(.touchEnabled, touchEnabled)
    longPressRightClick = v(.longPressRightClick, longPressRightClick)
    horizontalMoveDrags = v(.horizontalMoveDrags, horizontalMoveDrags)
    scrollSpeed = v(.scrollSpeed, scrollSpeed)
    momentumScrolling = v(.momentumScrolling, momentumScrolling)
    restoreCursorAfterTouch = v(.restoreCursorAfterTouch, restoreCursorAfterTouch)
    dashboardEnabled = v(.dashboardEnabled, dashboardEnabled)
    splitEnabled = v(.splitEnabled, splitEnabled)
    splitSide = v(.splitSide, splitSide)
    splitLength = v(.splitLength, splitLength)
    mouseFenceEnabled = v(.mouseFenceEnabled, mouseFenceEnabled)
    fenceBypassWithOption = v(.fenceBypassWithOption, fenceBypassWithOption)
    dockLockEnabled = v(.dockLockEnabled, dockLockEnabled)
    evictWindows = v(.evictWindows, evictWindows)
    ensureNativeResolution = v(.ensureNativeResolution, ensureNativeResolution)
    terminalEnabled = v(.terminalEnabled, terminalEnabled)
    terminalSide = v(.terminalSide, terminalSide)
    terminalWidth = v(.terminalWidth, terminalWidth)
    terminalFontSize = v(.terminalFontSize, terminalFontSize)
    terminalUseTmux = v(.terminalUseTmux, terminalUseTmux)
    pages = DashboardPage.normalized(v(.pages, pages))
    if pages.isEmpty { pages = DashboardPage.defaultPages }
    // Settings from before pages existed: keep the user's widgets on page 1 in column order.
    if (try? c.decodeIfPresent([DashboardPage].self, forKey: .pages)) == nil,
       let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([String].self, forKey: .widgets) {
      pages = Self.migratedPages(from: legacy)
    }
    launcherItems = v(.launcherItems, launcherItems)
    webURL = v(.webURL, webURL)
    webZoom = v(.webZoom, webZoom)
    discordClientID = v(.discordClientID, discordClientID)
    notificationsEnabled = v(.notificationsEnabled, notificationsEnabled)
    quotaFeedURL = v(.quotaFeedURL, quotaFeedURL)
    recorderScript = v(.recorderScript, recorderScript)
    recorderName = v(.recorderName, recorderName)
    sonosRoom = v(.sonosRoom, sonosRoom)
    sonosPlayers = v(.sonosPlayers, sonosPlayers)
    mediaItems = v(.mediaItems, mediaItems)
    profiles = v(.profiles, profiles)
  }
}

/// How the Edge is used: all dashboard, dashboard on one end with windows on the rest, or a regular display.
enum EdgeMode: CaseIterable {
  case dashboard, split, display
}

extension AppSettings {
  var edgeMode: EdgeMode {
    get { !dashboardEnabled ? .display : splitEnabled ? .split : .dashboard }
    set {
      dashboardEnabled = newValue != .display
      if newValue != .display { splitEnabled = newValue == .split }
    }
  }
}

extension AppSettings {
  private enum LegacyKeys: String, CodingKey { case widgets }

  /// Settings from before pages: start from the default layout, keeping only the widget kinds the
  /// user had (mapped onto today's kinds) plus anything new.
  static func migratedPages(from legacy: [String]) -> [DashboardPage] {
    let had = Set(legacy.compactMap(WidgetKind.migrating))
    let keep: Set<WidgetKind> = [.aiUsage]
    return DashboardPage.defaultPages.map { page in
      DashboardPage(slots: page.slots.filter { had.contains($0.kind) || keep.contains($0.kind) })
    }.filter { !$0.slots.isEmpty }
  }
}

/// Observable settings store persisted to UserDefaults as JSON.
final class SettingsStore: ObservableObject {
  static let shared = SettingsStore()
  private static let key = "settings.v1"

  @Published var settings: AppSettings {
    didSet {
      guard settings != oldValue else { return }
      save()
    }
  }

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
       let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
      settings = decoded
    } else {
      settings = AppSettings()
    }
  }

  func profile(for key: String) -> EdgeProfile {
    settings.profiles[key] ?? EdgeProfile()
  }

  func updateProfile(for key: String, _ change: (inout EdgeProfile) -> Void) {
    var p = profile(for: key)
    change(&p)
    settings.profiles[key] = p
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    UserDefaults.standard.set(data, forKey: Self.key)
  }
}
