import AppKit
import ApplicationServices
import EdgeCore

/// Answers and ends iPhone calls taken on the Mac through the Phone app (Continuity).
///
/// There is no public API for this: CallKit's call observer is unavailable to AppKit apps, and the
/// private call center rejects any client without Apple's "access-calls" entitlement. So the call
/// controls are found the way VoiceOver finds them, by reading the incoming-call alert and in-call
/// window through Accessibility and pressing their own Answer, Decline and End buttons. Nothing is
/// offered unless exactly that button is on screen.
///
/// macOS launches the Phone app when a call comes in, so while Phone (or the call alert's service)
/// is not running nothing is scanned at all. While it runs, small windows are read once a second
/// and the Phone app's main window (contacts and recents, slow to read) every fifth second.
@MainActor
final class PhoneController: ObservableObject {
  static let shared = PhoneController()

  @Published private(set) var state: PhoneCallState = .idle
  /// An incoming call's Answer button is on screen.
  @Published private(set) var canAnswer = false
  /// Decline (ringing) or End (in a call) is on screen.
  @Published private(set) var canHangUp = false
  /// Accessibility is granted; without it only "open Phone" works.
  @Published private(set) var trusted = AXIsProcessTrusted()

  nonisolated static let phoneBundleID = "com.apple.mobilephone"

  private let scanner = CallScanner()
  private let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.phone", qos: .utility)
  private var users = 0
  private var timer: Timer?
  private var tick = 0
  private var scanning = false

  func retain() {
    users += 1
    guard users == 1 else { return }
    refresh(full: true)
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh(full: false) }
    }
    t.tolerance = 0.25
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }

  /// Answers the ringing call; with no call ringing, opens (or launches) the Phone app.
  func answer() {
    guard trusted, canAnswer else {
      openPhone()
      return
    }
    act(.answer)
  }

  /// Declines a ringing call or ends the current one.
  func hangUp() {
    guard trusted, canHangUp else { return }
    act(.hangUp)
  }

  func openAccessibilitySettings() {
    Permissions.requestAccessibility()
    Permissions.openAccessibilitySettings()
  }

  // MARK: Private

  private func openPhone() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.phoneBundleID) else {
      Log.error(.dashboard, "phone: Phone app not found")
      return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
      if let error { Log.error(.dashboard, "phone: opening Phone failed: \(error.localizedDescription)") }
    }
  }

  private func act(_ action: CallScanner.Action) {
    queue.async { [scanner] in
      let match = scanner.perform(action)
      DispatchQueue.main.async { self.apply(match) }
    }
    // Read the outcome back once the call UI has had a moment to change.
    for delay in [0.5, 1.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh(full: true) }
    }
  }

  private func refresh(full: Bool) {
    let isTrusted = AXIsProcessTrusted()
    if isTrusted != trusted { trusted = isTrusted }
    guard isTrusted else {
      apply(.idle)
      return
    }
    guard !scanning else { return }
    tick += 1
    let includeMain = full || tick % 5 == 0
    scanning = true
    queue.async { [scanner] in
      let match = scanner.scan(includeMainWindows: includeMain)
      DispatchQueue.main.async {
        self.scanning = false
        self.apply(match)
      }
    }
  }

  private func apply(_ match: CallMatch) {
    if match.state != state { state = match.state }
    let answer = match.state == .ringing && match.answer != nil
    if answer != canAnswer { canAnswer = answer }
    let hangUp = match.hangUp != nil
    if hangUp != canHangUp { canHangUp = hangUp }
  }
}

/// Reads call controls through Accessibility. Used only on PhoneController's queue.
final class CallScanner: @unchecked Sendable {
  enum Action { case answer, hangUp }

  /// Processes that draw call controls: the Phone app's call windows, Notification Center (the
  /// incoming-call alert is a custom alert there) and the services that render that alert.
  private static let alertServices = ["com.apple.facetime.NotificationViewBridgeService", "com.apple.FaceTime.FaceTimeNotificationExtension"]
  private static let notificationCenter = "com.apple.notificationcenterui"
  /// Containers in Phone's main window that hold contacts and history, never call controls.
  private static let prunedRoles: Set<String> = ["AXScrollArea", "AXTable", "AXList", "AXOutline", "AXMenuBar", "AXMenu"]
  private static let nodeLimit = 400

  private let labels = CallScanner.loadLabels()
  private var controls: [CallControl] = []
  private var elements: [AXUIElement] = []
  /// The Phone main window's buttons, kept between its (slower) reads.
  private var mainControls: [(label: String, element: AXUIElement)] = []
  private var lastSignature = ""

  func scan(includeMainWindows: Bool) -> CallMatch {
    controls = []
    elements = []
    let phone = Self.running(PhoneController.phoneBundleID)
    let services = Self.alertServices.compactMap(Self.running)
    // macOS launches Phone for an incoming call, so without it (or the alert's service) there is
    // no call to find and nothing is read.
    guard phone != nil || !services.isEmpty else {
      mainControls = []
      if lastSignature != "" { Log.info(.dashboard, "phone: idle, Phone not running") }
      lastSignature = ""
      return .idle
    }
    var window = 0
    /// Button labels of the windows that look like call windows, for the log.
    var callWindows: [String] = []
    let callWords = labels.answer.union(labels.decline).union(labels.end).union(["accept"])

    func add(_ found: [(label: String, element: AXUIElement)], tag: String, alwaysLog: Bool) {
      for f in found {
        controls.append(CallControl(label: f.label, window: window))
        elements.append(f.element)
      }
      // Notification Center's other windows (desktop widgets, other apps' alerts) stay out of
      // the log unless they show a call word.
      if !found.isEmpty, alwaysLog || found.contains(where: { callWords.contains(CallLabels.normalize($0.label)) }) {
        callWindows.append("\(tag): " + found.map(\.label).prefix(12).map { String($0.prefix(30)) }.joined(separator: ", "))
      }
      window += 1
    }

    for app in services + [Self.running(Self.notificationCenter)].compactMap({ $0 }) {
      let isService = app.bundleIdentifier != Self.notificationCenter
      for w in Self.windows(of: app) { add(Self.buttons(in: w, pruned: false), tag: app.bundleIdentifier ?? "?", alwaysLog: isService) }
    }
    if let phone {
      var freshMain: [(label: String, element: AXUIElement)] = []
      var sawMain = false
      // The main window (contacts, recents) is the standard window titled after the app; call
      // windows are anything else.
      for w in Self.windows(of: phone) {
        if Self.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole, Self.string(w, kAXTitleAttribute) == phone.localizedName {
          sawMain = true
          if includeMainWindows { freshMain += Self.buttons(in: w, pruned: true) }
        } else {
          add(Self.buttons(in: w, pruned: false), tag: "phone-window", alwaysLog: true)
        }
      }
      if includeMainWindows || !sawMain { mainControls = freshMain }
      add(mainControls, tag: "phone-main", alwaysLog: false)
    } else {
      mainControls = []
    }

    let match = PhoneCall.match(controls, labels: labels)
    // Leave evidence of what a real call looked like (button labels only): log when the state,
    // the offered controls or the number of call windows change, not on every redraw.
    let signature = "\(match.state) \(match.answer != nil) \(match.hangUp != nil) \(callWindows.count)"
    if signature != lastSignature {
      Log.info(.dashboard, "phone: \(match.state), answer \(match.answer != nil), hang up \(match.hangUp != nil); buttons \(callWindows.joined(separator: " | "))")
      lastSignature = signature
    }
    return match
  }

  /// Re-reads the screen and presses the control only if the call is still in the state the tap
  /// was meant for.
  func perform(_ action: Action) -> CallMatch {
    let match = scan(includeMainWindows: true)
    let index: Int? = switch action {
    case .answer: match.state == .ringing ? match.answer : nil
    case .hangUp: match.hangUp
    }
    guard let index, index < elements.count else {
      Log.info(.dashboard, "phone: \(action) skipped, state now \(match.state)")
      return match
    }
    let result = AXUIElementPerformAction(elements[index], kAXPressAction as CFString)
    Log.info(.dashboard, "phone: \(action) pressed '\(controls[index].label)' in \(match.state) → \(result.rawValue)")
    return match
  }

  // MARK: Accessibility

  private static func running(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
  }

  private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.25)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  private static let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXRoleDescriptionAttribute] as CFArray

  /// Every button in a window with its label. `pruned` skips lists and collections, which in the
  /// Phone app's main window hold contacts and history.
  private static func buttons(in window: AXUIElement, pruned: Bool) -> [(label: String, element: AXUIElement)] {
    var found: [(label: String, element: AXUIElement)] = []
    var visited = 0
    func walk(_ e: AXUIElement, depth: Int) {
      guard depth < 16, visited < nodeLimit else { return }
      visited += 1
      var values: CFArray?
      guard AXUIElementCopyMultipleAttributeValues(e, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
            let v = values as? [AnyObject], v.count == 5 else { return }
      let role = v[0] as? String ?? ""
      if role == kAXButtonRole as String {
        let description = v[1] as? String ?? ""
        let label = description.isEmpty ? (v[2] as? String ?? "") : description
        if !label.isEmpty { found.append((label, e)) }
      }
      if pruned, prunedRoles.contains(role) || (v[4] as? String) == "collection" { return }
      for child in v[3] as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
    }
    walk(window, depth: 0)
    return found
  }

  private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  // MARK: Labels

  /// The call controls' own words from the system frameworks that draw them, in the Mac's
  /// languages, plus the built-in English and Korean.
  private static func loadLabels() -> CallLabels {
    let root = "/System/iOSSupport/System/Library/PrivateFrameworks"
    let notificationUI = table("\(root)/FaceTimeNotificationUI.framework/Resources/Localizable.loctable")
    let conversationKit = table("\(root)/ConversationKit.framework/Resources/ConversationKit.loctable")
    let languages = Locale.preferredLanguages + ["en"]
    let system = CallLabels(
      answer: CallLabels.strings(in: notificationUI, keys: ["ANSWER"], languages: languages),
      decline: CallLabels.strings(in: notificationUI, keys: ["DECLINE"], languages: languages),
      end: CallLabels.strings(in: notificationUI, keys: ["END"], languages: languages)
        .union(CallLabels.strings(in: conversationKit, keys: ["AX_HANG_UP", "DRAWER_END_AX", "IN_CALL_CONTROLS_END_LABEL"], languages: languages))
    )
    let labels = CallLabels.builtIn.union(system)
    Log.info(.dashboard, "phone: call labels answer \(labels.answer.sorted()), decline \(labels.decline.sorted()), end \(labels.end.sorted())")
    return labels
  }

  private static func table(_ path: String) -> [String: [String: String]] {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
    var out: [String: [String: String]] = [:]
    for (locale, strings) in plist {
      if let dict = strings as? [String: Any] { out[locale] = dict.compactMapValues { $0 as? String } }
    }
    return out
  }
}
