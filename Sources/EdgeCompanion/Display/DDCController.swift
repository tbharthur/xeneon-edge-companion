import EdgeCore
import Foundation
import IOKit

// Private IOKit entry points used by MonitorControl, Lunar and m1ddc for DDC on Apple Silicon.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn

/// DDC/CI access to one display. The Edge is limited to the colour VCP codes in `EdgeVCP`; a desk
/// monitor to the audio codes in `MonitorAudioVCP`; any display to brightness while the office is
/// away (`AwayBrightness`).
/// All I/O runs on one serial queue; the bus is slow (tens of ms per transaction) and shared
/// with MonitorControl, so we keep transactions short and spaced. Queue confinement makes it safe
/// to hand between threads.
final class DDCController: @unchecked Sendable {
  enum Display: Equatable {
    /// The Corsair Xeneon Edge.
    case edge
    /// The first external display that is not the Edge.
    case monitor
    /// The external display whose framebuffer has this IORegistry path (`IODisplayLocation`).
    case located(String)

    func framebuffers() -> [IORegistryDisplays.Framebuffer] {
      switch self {
      case .edge: return IORegistryDisplays.edgeFramebuffers()
      case .monitor: return IORegistryDisplays.monitorFramebuffers()
      case let .located(path):
        var all = IORegistryDisplays.framebuffers { _ in true }
        all.removeAll { fb in
          guard fb.location != path else { return false }
          IOObjectRelease(fb.avServiceEntry)
          return true
        }
        return all
      }
    }

    /// Desk monitors drop the first request frame; the Edge does not.
    var isMonitorLike: Bool { self != .edge }
  }

  enum DDCError: Error, CustomStringConvertible {
    case noService
    case noReply(UInt8)
    case unsupported(UInt8)

    var description: String {
      switch self {
      case .noService: return "DDC service not found"
      case let .noReply(v): return String(format: "no reply for VCP 0x%02X", v)
      case let .unsupported(v): return String(format: "VCP 0x%02X unsupported", v)
      }
    }
  }

  let queue: DispatchQueue
  let display: Display
  private var service: CFTypeRef?
  /// The framebuffer path of the cached service; transactions on one display share a lock
  /// across controllers, so two features never interleave frames on the same bus.
  private var busKey: String?
  private static let busLocksLock = NSLock()
  private static var busLocks: [String: NSLock] = [:]
  /// Product name of the display the cached service belongs to (queue-confined).
  private(set) var productName: String?

  init(display: Display = .edge) {
    self.display = display
    queue = DispatchQueue(label: "pro.seol.EdgeCompanion.ddc.\(display)", qos: .utility)
  }

  /// Drops the cached service; call when the Edge disconnects.
  func invalidate() {
    queue.async {
      self.service = nil
      self.productName = nil
      self.busKey = nil
    }
  }

  // MARK: Queue-confined API (call only from `queue`)

  func read(_ vcp: EdgeVCP) throws -> DDCPacket.VCPReply {
    precondition(display == .edge)
    return try read(code: vcp.rawValue)
  }

  func write(_ vcp: EdgeVCP, _ value: UInt16) throws {
    precondition(display == .edge)
    try write(code: vcp.rawValue, value)
  }

  func read(_ vcp: MonitorAudioVCP) throws -> DDCPacket.VCPReply {
    precondition(display == .monitor)
    return try read(code: vcp.rawValue)
  }

  func write(_ vcp: MonitorAudioVCP, _ value: UInt16) throws {
    precondition(display == .monitor)
    try write(code: vcp.rawValue, value)
  }

  /// Brightness (MCCS 0x10), for dimming while the office is away.
  func readBrightness() throws -> DDCPacket.VCPReply {
    try read(code: AwayBrightness.vcp)
  }

  func writeBrightness(_ value: UInt16) throws {
    try write(code: AwayBrightness.vcp, value)
  }

  private func onBus<T>(_ body: (CFTypeRef) throws -> T) throws -> T {
    let svc = try resolveService()
    guard let key = busKey, !key.isEmpty else { return try body(svc) }
    Self.busLocksLock.lock()
    let lock = Self.busLocks[key] ?? NSLock()
    Self.busLocks[key] = lock
    Self.busLocksLock.unlock()
    lock.lock()
    defer { lock.unlock() }
    return try body(svc)
  }

  private func read(code vcp: UInt8) throws -> DDCPacket.VCPReply {
    try onBus { svc in try read(code: vcp, svc: svc) }
  }

  private func read(code vcp: UInt8, svc: CFTypeRef) throws -> DDCPacket.VCPReply {
    var request = DDCPacket.getVCP(vcp)
    // The LG desk monitor drops the first request frame and answers an empty "not ready" reply,
    // so a monitor gets the request twice, 10 ms apart, as m1ddc sends it (measured on the LG:
    // about 1 in 10 reads answered with one frame, 8-9 in 10 with two). It also gets more tries.
    let frames = display.isMonitorLike ? 2 : 1
    let attempts = display.isMonitorLike ? 6 : 5
    for attempt in 0 ..< attempts {
      for _ in 0 ..< frames {
        usleep(10000)
        _ = IOAVServiceWriteI2C(svc, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), &request, UInt32(request.count))
      }
      usleep(display.isMonitorLike ? 40000 : 50000)
      var reply = [UInt8](repeating: 0, count: 11)
      if IOAVServiceReadI2C(svc, UInt32(DDCPacket.chipAddress), 0, &reply, UInt32(reply.count)) == kIOReturnSuccess {
        switch DDCPacket.parseReply(reply, expecting: vcp) {
        case let .success(r): return r
        case let .failure(.unsupported(code)) where attempt >= 1:
          _ = code
          throw DDCError.unsupported(vcp)
        case .failure: break
        }
      }
      usleep(30000)
    }
    throw DDCError.noReply(vcp)
  }

  private func write(code vcp: UInt8, _ value: UInt16) throws {
    try onBus { svc in try write(code: vcp, value, svc: svc) }
  }

  private func write(code vcp: UInt8, _ value: UInt16, svc: CFTypeRef) throws {
    var packet = DDCPacket.setVCP(vcp, value: value)
    // Sent twice, 10 ms apart, as MonitorControl does; some scalers drop the first frame.
    var ok = false
    for _ in 0 ..< 2 {
      usleep(10000)
      ok = IOAVServiceWriteI2C(svc, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess || ok
    }
    if !ok { throw DDCError.noReply(vcp) }
    // Give the scaler time to commit before the next transaction.
    usleep(60000)
  }

  private func resolveService() throws -> CFTypeRef {
    if let service { return service }
    let framebuffers = display.framebuffers()
    defer { framebuffers.forEach { IOObjectRelease($0.avServiceEntry) } }
    guard let fb = framebuffers.first,
          let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, fb.avServiceEntry)?.takeRetainedValue() else {
      throw DDCError.noService
    }
    service = svc
    productName = fb.productName
    busKey = fb.location
    return svc
  }
}
