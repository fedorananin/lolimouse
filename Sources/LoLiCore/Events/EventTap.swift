// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import ApplicationServices
import Foundation
import HIDKit
import os.log

/// The system-wide event tap, plus the watchdog that keeps it alive.
///
/// macOS disables a tap whenever it decides the owner was too slow, and revokes
/// it outright if the Accessibility grant is withdrawn — both silently. Without
/// a watchdog the app looks like it is running while doing nothing at all,
/// which is one of the more annoying ways for a tool like this to fail.
public final class EventTap {
    private static let log = LoLiLog.events

    public typealias Handler = (CGEvent, CGEventType) -> CGEvent?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: CFRunLoopTimer?
    private let handler: Handler

    /// Called when the tap could not be created or was revoked.
    public var onPermissionLost: (() -> Void)?

    /// Exactly the events LoLiMouse acts on, and nothing else.
    ///
    /// Every event type listed here is routed through this process before it
    /// reaches anything else on the machine. Pointer movement in particular
    /// arrives hundreds of times a second and LoLiMouse has no use for it, so
    /// asking for it would be pure risk: the more traffic the tap carries, the
    /// more chances macOS has to decide we are too slow and switch it off.
    public static let defaultWatchedEvents: [CGEventType] = [
        .scrollWheel,
        .otherMouseDown, .otherMouseUp,
    ]

    /// The event types this tap asks for. Fixed at creation; the caller
    /// replaces the tap to widen or narrow it, which keeps "what are we
    /// listening to" a decision made in exactly one place.
    public let watchedEvents: [CGEventType]

    public init(watchedEvents: [CGEventType] = EventTap.defaultWatchedEvents,
                handler: @escaping Handler) {
        self.watchedEvents = watchedEvents
        self.handler = handler
    }

    deinit { stop() }

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility if it has not been granted yet.
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func start() -> Bool {
        EventThread.shared.start()

        let created = EventThread.shared.perform { [weak self] () -> Bool in
            self?.createTap() ?? false
        } ?? false

        if created {
            startWatchdog()
        } else {
            os_log("could not create the event tap — Accessibility is probably not granted",
                   log: Self.log, type: .error)
            onPermissionLost?()
        }
        return created
    }

    public func stop() {
        EventThread.shared.perform { [weak self] in
            self?.destroyTap()
        }
        if let watchdogTimer {
            CFRunLoopTimerInvalidate(watchdogTimer)
            self.watchdogTimer = nil
        }
    }

    public var isRunning: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    // MARK: - Internals, all on the event thread

    private func createTap() -> Bool {
        destroyTap()

        let mask = watchedEvents.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()

        // `.cghidEventTap` is the earliest point in the pipeline, ahead of the
        // window server. Anything later and some applications would already
        // have seen the untransformed event.
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        machPort = port
        runLoopSource = source
        os_log("event tap installed", log: Self.log, type: .info)
        return true
    }

    private func destroyTap() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<EventTap>.fromOpaque(context).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system tells us through these two types that it switched the tap
        // off. Turning it straight back on is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            os_log("event tap was disabled (%{public}@); re-enabling",
                   log: Self.log, type: .error,
                   type == .tapDisabledByTimeout ? "timeout" : "user input")
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let result = handler(event, type) else {
            return nil // swallow it
        }
        return Unmanaged.passUnretained(result)
    }

    private func startWatchdog() {
        watchdogTimer = EventThread.shared.scheduleTimer(interval: 10) { [weak self] in
            guard let self else { return }

            if !EventTap.hasAccessibilityPermission {
                os_log("Accessibility permission was revoked", log: Self.log, type: .error)
                destroyTap()
                DispatchQueue.main.async { [weak self] in self?.onPermissionLost?() }
                return
            }

            guard let machPort else {
                _ = createTap()
                return
            }
            if !CGEvent.tapIsEnabled(tap: machPort) {
                os_log("event tap found disabled by the watchdog; re-enabling",
                       log: Self.log, type: .error)
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
        }
    }
}
