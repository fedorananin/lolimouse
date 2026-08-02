// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// A dedicated high-priority thread with its own run loop, owned by the event
/// tap.
///
/// This is not an optimisation. A CGEvent tap callback runs synchronously in
/// the path of every input event in the system, and macOS disables any tap that
/// takes too long to answer. Running the tap on a shared queue means an
/// unrelated piece of work can stall input for the whole machine — and then the
/// tap silently switches off. A private thread at `userInteractive` keeps that
/// from happening.
public final class EventThread {
    private static let log = LoLiLog.events
    public static let shared = EventThread()

    private var thread: Thread?
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {}

    public var isCurrent: Bool { Thread.current === thread }

    public func start() {
        guard thread == nil else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = RunLoop.current
            runLoop = loop.getCFRunLoop()
            // A run loop with no input sources exits immediately, so give it a
            // port to hold it open. `CFRunLoopSourceCreate` is not usable here:
            // its context argument is mandatory and passing null traps.
            loop.add(Port(), forMode: .common)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "\(LoLiLog.subsystem).events"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()

        _ = ready.wait(timeout: .now() + 2)
    }

    public func stop() {
        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
        thread = nil
        self.runLoop = nil
    }

    /// Runs `work` on the event thread, waiting for the result.
    ///
    /// Returns `nil` if the thread is not running, so callers can fall back to
    /// doing the work in place rather than deadlocking.
    @discardableResult
    public func perform<T>(_ work: @escaping () -> T) -> T? {
        if isCurrent { return work() }
        guard let runLoop else { return nil }

        var result: T?
        let semaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            result = work()
            semaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            os_log("event thread did not answer in time", log: Self.log, type: .error)
            return nil
        }
        return result
    }

    /// Schedules a repeating timer on the event thread.
    public func scheduleTimer(interval: TimeInterval, _ handler: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let runLoop else { return nil }
        let timer = CFRunLoopTimerCreateWithHandler(
            nil,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0
        ) { _ in handler() }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        return timer
    }
}
