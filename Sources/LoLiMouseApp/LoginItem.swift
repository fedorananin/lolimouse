// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log
import ServiceManagement

/// "Start at login", backed by `SMAppService`.
///
/// The system owns this state, not the configuration file: the user can flip
/// it in System Settings → General → Login Items behind our back, which is why
/// the value is re-read on every appearance rather than cached.
@MainActor
final class LoginItem: ObservableObject {
    private static let log = LoLiLog.app

    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Registration points at the running bundle, so the usual cause is
            // running a stray copy from the build directory rather than the
            // installed one.
            os_log("login item change failed: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            lastError = error.localizedDescription
        }
        refresh()
    }
}
