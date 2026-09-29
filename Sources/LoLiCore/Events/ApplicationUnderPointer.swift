// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import CoreGraphics
import Foundation

/// Finds the application whose window is under the pointer.
///
/// That, and not the frontmost application, is where macOS sends wheel events
/// and most clicks: a background window scrolls without being activated. So
/// it is also what decides which application profile applies.
///
/// The answer comes from the window server's on-screen window list, the same
/// technique LinearMouse uses. Fetching that list is a round trip to the
/// window server, so it is cached briefly — a wheel produces far more events
/// than windows move — and callers only ask while some profile actually
/// exists. No permission is needed: window titles would require Screen
/// Recording, but owners and bounds do not.
///
/// Safe to call from any thread.
public final class ApplicationUnderPointer {
    public static let shared = ApplicationUnderPointer()

    /// One on-screen window, as much of it as the lookup needs.
    public struct Window: Equatable, Sendable {
        public var ownerPID: pid_t
        public var bounds: CGRect
        public var layer: Int
        public var alpha: Double

        public init(ownerPID: pid_t, bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
            self.ownerPID = ownerPID
            self.bounds = bounds
            self.layer = layer
            self.alpha = alpha
        }
    }

    /// Long enough to cover a burst of wheel events, short enough that moving
    /// the pointer onto another window is noticed straight away.
    static let cacheLifetime: TimeInterval = 0.05

    private let lock = NSLock()
    private var windows: [Window] = []
    private var fetchedAt: TimeInterval = -.infinity
    private var bundleIdentifiers: [pid_t: String] = [:]
    private var terminationObserver: NSObjectProtocol?

    private init() {
        // A process ID is reused only after its owner has gone, so forgetting
        // it on termination keeps the cache honest.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            lock.lock()
            bundleIdentifiers.removeValue(forKey: application.processIdentifier)
            lock.unlock()
        }
    }

    /// The bundle identifier of the application owning the topmost window at
    /// `point`, in global display coordinates with the origin at the top left —
    /// the same space as `CGEvent.location`. `nil` over the desktop, the menu
    /// bar or the Dock.
    public func bundleIdentifier(at point: CGPoint) -> String? {
        guard let pid = Self.owner(at: point, in: currentWindows()) else { return nil }
        return bundleIdentifier(of: pid)
    }

    /// The same, for wherever the pointer is right now. For callers that have
    /// no event to take a location from: HID++ button notifications and
    /// trackpad taps.
    public func bundleIdentifierUnderPointer() -> String? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        return bundleIdentifier(at: location)
    }

    /// The owner of the frontmost application window containing `point`.
    /// `windows` is in the window server's order, front to back.
    public static func owner(at point: CGPoint, in windows: [Window]) -> pid_t? {
        windows.first { window in
            isApplicationLayer(window.layer) && window.alpha > 0 && window.bounds.contains(point)
        }?.ownerPID
    }

    /// Ordinary windows sit at layer 0, and floating panels — IINA's
    /// "float on top", picture in picture — a little above it. The Dock, the
    /// menu bar and everything over them start at the Dock's level, and those
    /// belong to the system rather than to the application under them.
    static func isApplicationLayer(_ layer: Int) -> Bool {
        layer >= 0 && layer < dockLayer
    }

    private static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    private func currentWindows() -> [Window] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if now - fetchedAt < Self.cacheLifetime {
            let cached = windows
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Fetched outside the lock: it is the slow part, and two threads
        // occasionally fetching at once costs less than one waiting.
        let fresh = Self.fetchWindows()

        lock.lock()
        windows = fresh
        fetchedAt = now
        lock.unlock()
        return fresh
    }

    private func bundleIdentifier(of pid: pid_t) -> String? {
        lock.lock()
        let cached = bundleIdentifiers[pid]
        lock.unlock()
        if let cached { return cached }

        // `NSRunningApplication` is documented as thread safe.
        guard let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        lock.lock()
        bundleIdentifiers[pid] = identifier
        lock.unlock()
        return identifier
    }

    private static func fetchWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return Window(ownerPID: pid, bounds: bounds, layer: layer, alpha: alpha)
        }
    }
}
