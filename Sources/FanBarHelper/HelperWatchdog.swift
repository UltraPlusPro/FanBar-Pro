import Darwin
import FanBarShared
import Foundation
import os

/// Last-resort guard against a wedged hardware queue.
///
/// Every hardware call runs on one serial queue. If an SMC exchange never
/// returns — seen after a bad sleep/wake or a firmware hiccup — that queue, and
/// with it every later read and write, is stuck forever. launchd still sees a
/// live process, so `KeepAlive` never fires and the app only reports timeouts
/// until the user restarts the Mac.
///
/// The watchdog is armed by the queue itself around each client-facing
/// operation. When one operation has been running past `limit`, it exits
/// non-zero on purpose: launchd's `KeepAlive`(`SuccessfulExit=false`) restarts
/// the daemon within a second, the app's reply gate times out, and
/// `HelperClient.onConnectionReset` re-applies the mode the user chose. A
/// restart is always cheaper than a daemon that answers nothing — and unlike a
/// kill, it leaves the SMC session closed, which is exactly the state that
/// clears a wedged transfer.
final class HelperWatchdog: @unchecked Sendable {
    private static let log = Logger(subsystem: FanBarService.helperBundleID, category: "watchdog")

    private let lock = NSLock()
    private var operation: String?
    private var startedAt: Date?
    private let limit: TimeInterval
    private let pollInterval: TimeInterval
    private var timer: DispatchSourceTimer?

    init(limit: TimeInterval = 12, pollInterval: TimeInterval = 2) {
        self.limit = limit
        self.pollInterval = pollInterval
    }

    /// Called by the hardware queue before it touches the SMC.
    func begin(_ name: String) {
        lock.lock()
        operation = name
        startedAt = Date()
        lock.unlock()
    }

    /// Called when the operation returned, however it ended.
    func end() {
        lock.lock()
        operation = nil
        startedAt = nil
        lock.unlock()
    }

    /// Starts sampling on its own queue. Sampling must not share the hardware
    /// queue: a blocked queue is exactly what this type has to notice.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "local.fanbar.helper.watchdog", qos: .utility)
        )
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        lock.lock()
        let name = operation
        let start = startedAt
        lock.unlock()
        guard let name, let start else { return }
        let elapsed = Date.now.timeIntervalSince(start)
        guard elapsed > limit else { return }
        Self.log.fault(
            "Hardware operation \(name, privacy: .public) has not returned in \(elapsed, format: .fixed(precision: 1))s; exiting so launchd can restart the service"
        )
        RuntimeDiagnostics.shared.record(.helper, .recovery, .failed, value: elapsed)
        // EXIT_FAILURE, not exit(0): `KeepAlive` only restarts a failed exit.
        exit(EXIT_FAILURE)
    }
}
