// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Permissions")
                    .font(.title2.weight(.semibold))

                Text("macOS keeps input under lock and key. LoLiMouse needs two grants, and nothing "
                    + "else — no kernel extension, no driver, no background daemon running as root.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PermissionCard(
                    title: "Accessibility",
                    granted: controller.hasAccessibility,
                    explanation: "Lets LoLiMouse see and reshape scroll and button events. Without it "
                        + "scrolling, gestures and button remapping do nothing.",
                    action: "Grant…",
                    onGrant: {
                        controller.requestAccessibility()
                        controller.openPrivacyPane("Privacy_Accessibility")
                    }
                )

                PermissionCard(
                    title: "Input Monitoring",
                    granted: controller.hasInputMonitoring,
                    explanation: "Lets LoLiMouse talk to the mouse directly over HID++. Without it the "
                        + "ratchet, DPI and the extra buttons cannot be configured.",
                    action: "Grant…",
                    onGrant: {
                        controller.requestInputMonitoring()
                        controller.openPrivacyPane("Privacy_ListenEvent")
                    }
                )

                Text("After granting a permission you may need to quit and reopen LoLiMouse once. "
                    + "macOS ties permissions to the app's code signature, so a freshly rebuilt copy "
                    + "counts as a different app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Re-scan devices") { controller.registry.rescan() }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionCard: View {
    let title: String
    let granted: Bool
    let explanation: String
    let action: String
    let onGrant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !granted {
                Button(action, action: onGrant)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AboutView: View {
    /// The repository this app is published from.
    static let repositoryURL = URL(string: "https://github.com/fedorananin/lolimouse")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LoLiMouse").font(.largeTitle.weight(.semibold))
                Text("One app for the whole mouse, on macOS.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Version \(Self.version)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Link("github.com/fedorananin/lolimouse", destination: Self.repositoryURL)
                        .font(.callout)
                }

                Text("""
                LoLiMouse configures Logitech mice over HID++ and reshapes scrolling and buttons \
                through a system event tap — the two halves that normally take two separate \
                applications fighting each other.

                Two things it does differently:

                • Every setting has its own switch. Nothing is written to your mouse or to macOS \
                unless you turned that specific setting on, and turning it back off restores what \
                was there before. That is why LoLiMouse can share a machine with other tools \
                instead of arguing with them.

                • Settings survive a reconnect. The mouse forgets its ratchet, DPI and diverted \
                buttons every time it powers down; LoLiMouse notices it come back, reapplies \
                everything, and confirms the write a few seconds later to beat the firmware's own \
                start-up.
                """)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Free software under the MIT licence.")
                    .font(.callout)
                Text("""
                An independent project, not a fork. Protocol details and a number of hard-won \
                implementation techniques were learned from LinearMouse (MIT) and OpenLogi \
                (MIT/Apache-2.0), both excellent and both worth your support.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The marketing version from the bundle, e.g. "0.1.0". A bare binary run
    /// outside the bundle (swift run) has no Info.plist to read.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
