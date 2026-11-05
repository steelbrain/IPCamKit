// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT
// Runs tests that launch mediamtx and ffmpeg one at a time across suites

import Testing

/// FIFO async mutex shared by every test that launches a local mediamtx.
actor LiveServerLock {
  static let shared = LiveServerLock()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard held else {
      held = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      held = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

/// `.serialized` orders tests within one suite, but suites run in parallel.
/// The live fixtures pick free ports by binding and releasing them before
/// mediamtx starts, so two suites starting servers at once can pick the same
/// port ("bind: address already in use"). This trait holds `LiveServerLock`
/// around each test case of every suite that carries it.
struct LiveServerTrait: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  /// Scope each test case, not the suite as a whole: a suite holding the lock
  /// would block its own tests.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    testCase == nil ? nil : self
  }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    await LiveServerLock.shared.acquire()
    do {
      try await function()
    } catch {
      await LiveServerLock.shared.release()
      throw error
    }
    await LiveServerLock.shared.release()
  }
}

extension Trait where Self == LiveServerTrait {
  /// Run each test case alone among all tests that launch mediamtx.
  static var liveServer: Self { Self() }
}
