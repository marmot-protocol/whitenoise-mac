//
//  TestDoubles.swift
//  whitenoise-macTests
//
//  Reference-typed test doubles and concurrency gates shared by the suites split out of
//  `whitenoise_macTests.swift`. Moved verbatim from that file; `internal` rather than
//  `private` for the same reason `FakeMarmotRuntime` is — a file-scoped `private` here
//  would be invisible to every suite that needs one.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

/// Reference-typed boolean so a `@Sendable`/`@MainActor` provider closure can capture an
/// immutable reference whose value the test flips later, without tripping the "mutated after
/// capture by sendable closure" diagnostic that a captured `var` would.
final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

@MainActor
final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

@MainActor
final class InMemoryChatRestorationStore: ChatRestorationStoring {
    var isEnabled: Bool
    private(set) var targetsByAccount: [String: String]

    init(isEnabled: Bool = false, targetsByAccount: [String: String] = [:]) {
        self.isEnabled = isEnabled
        self.targetsByAccount = targetsByAccount
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func targetGroupId(forOwnerAccountIdHex accountIdHex: String) -> String? {
        targetsByAccount[accountIdHex]
    }

    func setTarget(groupIdHex: String, forOwnerAccountIdHex accountIdHex: String) {
        guard isEnabled else { return }
        targetsByAccount[accountIdHex] = groupIdHex
    }

    func removeTarget(forOwnerAccountIdHex accountIdHex: String) {
        targetsByAccount[accountIdHex] = nil
    }

    func clearTargets() {
        targetsByAccount = [:]
    }
}

@MainActor
final class InMemoryQuickReactionStore: QuickReactionStoring {
    private let loadedReactions: [String]
    private(set) var savedValues: [[String]] = []
    private(set) var resetCallCount = 0

    init(_ loadedReactions: [String] = ChatReactionDefaults.quick) {
        self.loadedReactions = loadedReactions
    }

    func load() -> [String] {
        loadedReactions
    }

    func save(_ reactions: [String]) {
        savedValues.append(reactions)
    }

    func reset() {
        resetCallCount += 1
    }
}

final class SuspendingMicrophoneAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private let requested = DispatchSemaphore(value: 0)

    @MainActor
    func provider() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock {
                permissionContinuation = continuation
            }
            requested.signal()
        }
    }

    func waitUntilRequested(timeout: DispatchTime = .now() + 2) async -> Bool {
        await waitForSemaphore(requested, timeout: timeout) == .success
    }

    func grantAccess() {
        resumePermissionRequest(granted: true)
    }

    func denyAccess() {
        resumePermissionRequest(granted: false)
    }

    private func resumePermissionRequest(granted: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            let continuation = permissionContinuation
            permissionContinuation = nil
            return continuation
        }
        continuation?.resume(returning: granted)
    }
}

func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

final class BlockingFfiGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var semaphore: DispatchSemaphore?
    private var reached = false

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var didReach: Bool {
        lock.withLock { reached }
    }

    func passIfArmed() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard enabled, self.semaphore == nil, !reached else { return nil }
            reached = true
            let semaphore = DispatchSemaphore(value: 0)
            self.semaphore = semaphore
            return semaphore
        }
        semaphore?.wait()
    }

    func release() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            let semaphore = self.semaphore
            self.semaphore = nil
            return semaphore
        }
        semaphore?.signal()
    }
}

/// Async twin of `BlockingFfiGate`: suspends the first armed call on a continuation, with all
/// gate state lock-guarded so arming, polling, and releasing from other threads cannot race the
/// suspension — a release that wins the race resumes the parked call immediately.
/// Snapshots of how many people the panel or sheet was showing as unreachable, taken while a press
/// was still working through the roster. A press that publishes its findings as it goes leaves a
/// rising sequence here; one that publishes them together leaves zeros.
@MainActor
final class MidPressMarkCounts {
    var counts: [Int] = []
}

final class AsyncFfiGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var reached = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var didReach: Bool {
        lock.withLock { reached }
    }

    func passIfArmed() async {
        let shouldSuspend = lock.withLock {
            enabled && continuation == nil && !reached
        }
        guard shouldSuspend else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                self.continuation = continuation
                reached = true
                if released {
                    self.continuation = nil
                    return true
                }
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

final class OneShotKeyProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let secondCallReached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let keyData: Data
    private var callCount = 0
    private var shouldBlock = true

    init(keyData: Data = Data(repeating: 0x42, count: 32)) {
        self.keyData = keyData
    }

    func symmetricKey() throws -> SymmetricKey {
        let (shouldWait, isSecondCall) = lock.withLock {
            callCount += 1
            let shouldWait = shouldBlock
            shouldBlock = false
            return (shouldWait, callCount == 2)
        }
        if isSecondCall {
            secondCallReached.signal()
        }
        if shouldWait {
            reached.signal()
            release.wait()
        }
        return SymmetricKey(data: keyData)
    }

    func waitUntilReached() {
        reached.wait()
    }

    func waitForSecondCall(timeout: DispatchTime) async -> DispatchTimeoutResult {
        await waitForSemaphore(secondCallReached, timeout: timeout)
    }

    func releaseGate() {
        release.signal()
    }
}

final class ObservationInvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    func markInvalidated() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
}

@MainActor
final class AppActivationRecorder {
    private(set) var requests: [Bool] = []

    func record(ignoringOtherApps: Bool) {
        requests.append(ignoringOtherApps)
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storedValue += 1
        let value = storedValue
        lock.unlock()
        return value
    }

    @discardableResult
    func decrement() -> Int {
        lock.lock()
        storedValue -= 1
        let value = storedValue
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class AtomicMax: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func record(_ value: Int) {
        lock.lock()
        storedValue = max(storedValue, value)
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

struct TranscriptPerformanceRows: View {
    let messages: [MessageItem]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(messages) { message in
                ConversationMessageRow(
                    message: message,
                    showsDebugMetadata: false
                ) { _ in
                } onNavigateToMessage: { _ in
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(width: 760)
    }
}
