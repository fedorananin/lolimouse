// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import os.log

/// Shared logging subsystem. Every module logs under `me.fedorananin.LoLiMouse`
/// with its own category so `log stream --predicate 'subsystem == "…"'` can
/// follow one area at a time.
public enum LoLiLog {
    public static let subsystem = "me.fedorananin.LoLiMouse"

    public static func make(_ category: String) -> OSLog {
        OSLog(subsystem: subsystem, category: category)
    }

    public static let hid = make("HID")
    public static let hidpp = make("HIDPP")
    public static let devices = make("Devices")
    public static let reconcile = make("Reconcile")
    public static let events = make("Events")
    public static let config = make("Config")
    public static let app = make("App")
}
