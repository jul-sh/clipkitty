@testable import ClipKittyiOS
import XCTest

@MainActor
final class iOSPasteboardMonitorTests: XCTestCase {
    func testDelayedActivationCheckCatchesEndOfRunLoopGeneration() async {
        let enabled = true
        var generation = 10
        var acknowledged = 10
        var attempts: [Int] = []
        var releaseActivationRetry: CheckedContinuation<Void, Never>?

        let monitor = iOSPasteboardMonitor(
            isEnabled: { enabled },
            changeCount: { generation },
            acknowledgedChangeCount: { acknowledged },
            notificationCenter: nil,
            pasteboard: nil,
            waitForActivationRetry: {
                await withCheckedContinuation { continuation in
                    releaseActivationRetry = continuation
                }
            },
            pollingInterval: .seconds(5),
            ingest: { value in
                attempts.append(value)
                acknowledged = value
                return .handled
            }
        )

        monitor.sceneBecameActive()
        await eventually { releaseActivationRetry != nil }
        // Model UIKit updating changeCount only after the activation callback,
        // then deterministically release the end-of-run-loop retry.
        generation = 11
        releaseActivationRetry?.resume()

        await eventually { attempts == [11] }
        _ = monitor.stop()
        XCTAssertTrue(enabled)
    }

    func testSignalsCoalesceWhileIngestRunsAndNewestGenerationWins() async {
        var generation = 1
        var acknowledged = 0
        var attempts: [Int] = []
        var releaseFirst: CheckedContinuation<Void, Never>?

        let monitor = iOSPasteboardMonitor(
            isEnabled: { true },
            changeCount: { generation },
            acknowledgedChangeCount: { acknowledged },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .seconds(5),
            pollingInterval: .seconds(5),
            ingest: { value in
                attempts.append(value)
                if value == 1 {
                    await withCheckedContinuation { continuation in
                        releaseFirst = continuation
                    }
                }
                if generation == value {
                    acknowledged = value
                }
                return .handled
            }
        )

        monitor.sceneBecameActive()
        await eventually { releaseFirst != nil }

        generation = 2
        monitor.pasteboardDidChange()
        monitor.pasteboardDidChange()
        monitor.pasteboardDidChange()
        releaseFirst?.resume()

        await eventually { attempts == [1, 2] }
        XCTAssertEqual(acknowledged, 2)
        _ = monitor.stop()
    }

    func testPollingReactsWhenAutoAddIsEnabledInPlace() async {
        var enabled = false
        let generation = 7
        var acknowledged = 0
        var attempts: [Int] = []

        let monitor = iOSPasteboardMonitor(
            isEnabled: { enabled },
            changeCount: { generation },
            acknowledgedChangeCount: { acknowledged },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .milliseconds(5),
            pollingInterval: .milliseconds(15),
            ingest: { value in
                attempts.append(value)
                acknowledged = value
                return .handled
            }
        )

        monitor.sceneBecameActive()
        try? await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(attempts.isEmpty)

        enabled = true
        await eventually { attempts == [7] }
        _ = monitor.stop()
    }

    func testTemporarilyUnavailableGenerationHasBoundedAutomaticRetries() async {
        var attempts: [Int] = []

        let monitor = iOSPasteboardMonitor(
            isEnabled: { true },
            changeCount: { 9 },
            acknowledgedChangeCount: { 0 },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .milliseconds(10),
            pollingInterval: .milliseconds(5),
            retryPollCount: 0,
            maximumAutomaticRetryCount: 2,
            ingest: { value in
                attempts.append(value)
                return .retry
            }
        )

        monitor.sceneBecameActive()
        await eventually { attempts.count == 4 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, [9, 9, 9, 9])

        // A real pasteboard notification is explicit authority for a fresh
        // attempt and its own bounded retry window.
        monitor.pasteboardDidChange()
        await eventually { attempts.count == 7 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, [9, 9, 9, 9, 9, 9, 9])
        _ = monitor.stop()
    }

    func testPollingContinuesWhileSceneIsForegroundInactive() async {
        var generation = 3
        var acknowledged = 3
        var attempts: [Int] = []

        let monitor = iOSPasteboardMonitor(
            isEnabled: { true },
            changeCount: { generation },
            acknowledgedChangeCount: { acknowledged },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .milliseconds(5),
            pollingInterval: .milliseconds(15),
            ingest: { value in
                attempts.append(value)
                acknowledged = value
                return .handled
            }
        )

        monitor.sceneBecameActive()
        // There is intentionally no inactive pause: Slide Over can remain
        // inactive while the adjacent app writes the pasteboard.
        generation = 4
        await eventually { attempts == [4] }
        _ = monitor.stop()
    }

    func testStopReturnsInFlightWorkForSuspensionToJoin() async {
        var release: CheckedContinuation<Void, Never>?
        var joined = false

        let monitor = iOSPasteboardMonitor(
            isEnabled: { true },
            changeCount: { 1 },
            acknowledgedChangeCount: { 0 },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .seconds(5),
            pollingInterval: .seconds(5),
            ingest: { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                }
                return .handled
            }
        )

        monitor.sceneBecameActive()
        await eventually { release != nil }

        guard case let .awaiting(inFlight) = monitor.stop() else {
            return XCTFail("Stopping during ingest must return joinable work")
        }
        Task { @MainActor in
            await inFlight.value
            joined = true
        }

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(joined)
        release?.resume()
        await eventually { joined }
    }

    func testStopPreventsLaterActivationAndPollingChecks() async {
        var generation = 1
        var acknowledged = 1
        var attempts: [Int] = []

        let monitor = iOSPasteboardMonitor(
            isEnabled: { true },
            changeCount: { generation },
            acknowledgedChangeCount: { acknowledged },
            notificationCenter: nil,
            pasteboard: nil,
            activationRetryDelay: .milliseconds(5),
            pollingInterval: .milliseconds(5),
            ingest: { value in
                attempts.append(value)
                acknowledged = value
                return .handled
            }
        )

        monitor.sceneBecameActive()
        _ = monitor.stop()
        generation = 2
        monitor.pasteboardDidChange()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(attempts.isEmpty)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}
