import Combine
import EdgeCore
import Foundation

/// Polls a local multi-account usage feed (address in `AppSettings.quotaFeedURL`) while the
/// account quotas widget is on screen. The feed does its own pacing upstream; this only reads it.
@MainActor
final class QuotaFeedService: ObservableObject {
  static let shared = QuotaFeedService()

  enum Status: Equatable { case waiting, ok, unreachable(String) }

  @Published private(set) var accounts: [QuotaAccountView] = []
  @Published private(set) var status: Status = .waiting
  /// Ticks with each poll so countdowns and expired windows refresh.
  @Published private(set) var now = Date()

  private var feed: QuotaFeed?
  private var users = 0
  private var timer: Timer?
  private var inFlight = false
  private static let pollSeconds: TimeInterval = 60

  func retain() {
    users += 1
    guard users == 1 else { return }
    poll()
    let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    t.tolerance = 10
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    now = Date()
    guard !inFlight else { return }
    guard let url = URL(string: SettingsStore.shared.settings.quotaFeedURL), url.scheme?.hasPrefix("http") == true else {
      status = .unreachable(tr("피드 주소가 없어요", "No feed address set"))
      rebuild(reachable: false)
      return
    }
    inFlight = true
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
      let decoded = ok ? data.flatMap { try? QuotaFeed.decode($0) } : nil
      let message = error?.localizedDescription ?? (ok ? tr("피드 형식을 읽을 수 없어요", "Unreadable feed") : tr("피드가 응답하지 않아요", "Feed not responding"))
      DispatchQueue.main.async {
        guard let self else { return }
        self.inFlight = false
        if let decoded {
          self.feed = decoded
          self.status = .ok
        } else {
          // Keep the last reading on screen, marked as unconfirmed.
          Log.error(.dashboard, "quota feed: \(message)")
          self.status = .unreachable(message)
        }
        self.rebuild(reachable: decoded != nil)
      }
    }.resume()
  }

  private func rebuild(reachable: Bool) {
    now = Date()
    accounts = feed.map { QuotaModel.accounts(from: $0, feedReachable: reachable, now: now) } ?? []
  }
}
