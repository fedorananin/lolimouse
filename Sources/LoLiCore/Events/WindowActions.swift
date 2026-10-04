// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import ApplicationServices
import Foundation
import HIDKit
import os.log

/// What has been minimised or hidden lately, newest last, so that it can be
/// brought back in reverse order.
///
/// Pure, so it can be tested without windows. `Window` is whatever identifies
/// one — an `AXUIElement` in the app, a number in the tests.
public struct RestoreHistory<Window: Equatable> {
    public enum Entry: Equatable {
        /// A window that was minimised, and the process it belongs to.
        case window(pid_t, Window)
        /// An application that was hidden.
        case application(pid_t)

        var pid: pid_t {
            switch self {
            case let .window(pid, _), let .application(pid): return pid
            }
        }
    }

    public private(set) var entries: [Entry] = []
    /// Nobody walks back through dozens of windows one swipe at a time; the
    /// limit only keeps a long session from growing the list for ever.
    public let capacity: Int

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Puts `entry` on top. Something sent away twice is remembered once, at
    /// its latest place.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0 == entry }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Drops everything belonging to a process that has gone.
    public mutating func forget(pid: pid_t) {
        entries.removeAll { $0.pid == pid }
    }

    /// Takes the newest entry off. The caller checks whether it is still
    /// away — the user may have brought it back by hand — and asks again if
    /// not.
    public mutating func takeLast() -> Entry? {
        entries.popLast()
    }
}

/// Minimises, hides and brings back windows and applications.
///
/// Minimising goes through Accessibility, which is a message to another
/// process and waits for its answer. `ActionRunner.run` is called from the
/// event tap's thread among others, and a tap whose owner answers slowly gets
/// disabled — so that work waits on a queue of its own.
final class WindowActions {
    private static let log = LoLiLog.events
    private static let queue = DispatchQueue(label: "me.fedorananin.LoLiMouse.windows", qos: .userInitiated)

    /// Guards `history`: it is written from the queue above and from the
    /// workspace's notifications.
    private let lock = NSLock()
    private var history = RestoreHistory<AXUIElement>()
    private var observers: [NSObjectProtocol] = []

    init() {
        // Hides are taken from the workspace rather than from our own action,
        // so that an application hidden with ⌘H comes back the same way. It
        // is a public notification and changes nothing by being listened to.
        // Minimising has no such notification short of an Accessibility
        // observer on every running application, so only windows minimised
        // from here are remembered.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = Self.processIdentifier(in: notification) else { return }
            self?.withHistory { $0.record(.application(pid)) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let pid = Self.processIdentifier(in: notification) else { return }
            self?.withHistory { $0.forget(pid: pid) }
        })
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Actions

    /// Minimises the focused window of the frontmost application.
    ///
    /// Through Accessibility rather than by sending ⌘M: the shortcut is the
    /// application's own menu item, and plenty of applications have none or
    /// have given the key to something else. ⌘M remains the fallback for an
    /// application that does not say which of its windows has the focus.
    func minimizeFrontWindow(fallback: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            guard let application = NSWorkspace.shared.frontmostApplication else { return }
            let pid = application.processIdentifier
            Self.queue.async { [self] in
                let element = Self.applicationElement(pid)
                guard let window = Self.element(of: element, kAXFocusedWindowAttribute) else {
                    os_log("no focused window from pid %d; sending ⌘M", log: Self.log, type: .info, pid)
                    fallback()
                    return
                }
                let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                guard result == .success else {
                    os_log("could not minimise the window of pid %d (AX error %d)",
                           log: Self.log, type: .error, pid, result.rawValue)
                    return
                }
                withHistory { $0.record(.window(pid, window)) }
            }
        }
    }

    func hideFrontApplication() {
        DispatchQueue.main.async {
            guard let application = NSWorkspace.shared.frontmostApplication else { return }
            if !application.hide() {
                os_log("%{public}@ refused to hide", log: Self.log, type: .error,
                       application.localizedName ?? "the frontmost application")
            }
        }
    }

    /// Brings back whatever was sent away last: the newest minimised window
    /// or hidden application that is still away. With nothing remembered —
    /// after a restart, or for a window minimised with ⌘M — it falls back to
    /// a minimised window of the application in front.
    func restoreLast() {
        DispatchQueue.main.async { [self] in
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Self.queue.async { [self] in
                while let entry = withHistory({ $0.takeLast() }) {
                    if restore(entry) { return }
                }
                if let frontmost, let window = Self.minimizedWindow(of: frontmost) {
                    Self.unminimize(window, of: frontmost)
                    return
                }
                os_log("nothing minimised or hidden to bring back", log: Self.log, type: .info)
            }
        }
    }

    /// Returns `false` when the entry is no longer away — brought back by
    /// hand, or its application has quit — so the caller tries the next one.
    private func restore(_ entry: RestoreHistory<AXUIElement>.Entry) -> Bool {
        switch entry {
        case let .window(pid, window):
            guard Self.isMinimized(window) else { return false }
            Self.unminimize(window, of: pid)
            return true

        case let .application(pid):
            // `NSRunningApplication` is documented as thread safe.
            guard let application = NSRunningApplication(processIdentifier: pid), application.isHidden else {
                return false
            }
            application.unhide()
            Self.bringToFront(pid)
            os_log("brought back %{public}@", log: Self.log, type: .info,
                   application.localizedName ?? "a hidden application")
            return true
        }
    }

    // MARK: - Accessibility

    private static func applicationElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        // A hung application must not hold the queue for the default six
        // seconds.
        AXUIElementSetMessagingTimeout(element, 1)
        return element
    }

    private static func element(of parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // The type ID was checked above; CoreFoundation types have no
        // conditional cast.
        return (value as! AXUIElement)
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func minimizedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let application = applicationElement(pid)
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first(where: isMinimized)
    }

    private static func unminimize(_ window: AXUIElement, of pid: pid_t) {
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard result == .success else {
            os_log("could not bring back the window of pid %d (AX error %d)",
                   log: log, type: .error, pid, result.rawValue)
            return
        }
        bringToFront(pid)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        os_log("brought back a window of pid %d", log: log, type: .info, pid)
    }

    /// Makes an application the active one.
    ///
    /// Through Accessibility as well as `NSRunningApplication.activate()`:
    /// since macOS 14 activation is cooperative, and a request from an
    /// application that is not itself in front — a menu bar agent never is —
    /// may be quietly ignored.
    private static func bringToFront(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementSetAttributeValue(applicationElement(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - History

    @discardableResult
    private func withHistory<Result>(_ body: (inout RestoreHistory<AXUIElement>) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&history)
    }

    private static func processIdentifier(in notification: Notification) -> pid_t? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }
}
