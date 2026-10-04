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
/// The same list also says whether Mission Control is up, which the trackpad
/// swipes need to know — see `isWindowOverviewShowing()`.
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

    // MARK: - Mission Control

    /// Whether Mission Control or App Exposé is covering a display right now.
    ///
    /// While either is up, three- and four-finger swipes are the system's:
    /// swiping down is how Mission Control is dismissed. LoLiMouse cannot keep
    /// a swipe from macOS, so the only way not to act on the same movement
    /// twice is to notice the overview and stand aside.
    ///
    /// There is no public notification for this. What gives it away is the
    /// overview's backdrop: a window the size of the display, just under the
    /// Dock's level. Measured on macOS 27, where it belongs to WindowManager,
    /// sits at layer 19, is on screen within 50 ms of the overview starting to
    /// open, and stays until about 0.3 s after it starts to close. Earlier
    /// versions are reported to draw it from the Dock at layer 18, which the
    /// same test covers; that has not been checked here.
    public func isWindowOverviewShowing() -> Bool {
        Self.overviewBackdropOwners(in: currentWindows(), displays: Self.displayBounds()).contains { pid in
            bundleIdentifier(of: pid).map(Self.overviewOwners.contains) ?? false
        }
    }

    /// The owners of every window that could be the overview's backdrop: one
    /// covering a whole display, above ordinary windows and below the Dock.
    /// Whether the owner is a process that draws the overview is the caller's
    /// question — a screenshot tool's full-screen overlay sits in the same
    /// place.
    public static func overviewBackdropOwners(in windows: [Window], displays: [CGRect]) -> [pid_t] {
        windows.filter { window in
            window.layer > 0 && window.layer < dockLayer && window.alpha > 0
                && displays.contains { window.bounds.contains($0) }
        }.map(\.ownerPID)
    }

    private static let overviewOwners: Set<String> = ["com.apple.WindowManager", "com.apple.dock"]

    /// Every active display, in the global coordinates window bounds use.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

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
