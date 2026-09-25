// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import HIDPP

/// Formats the charge readings shown next to the menu bar icon.
///
/// Kept in LoLiCore, away from AppKit, so the rules can be tested: only
/// devices the user opted in are shown, in the registry's (alphabetical)
/// order, and a device that has not reported a level yet is skipped rather
/// than blanking out the ones that have. Bare numbers separated by a middle
/// dot — with two devices a glyph could not tell one mouse from another
/// anyway, and the menu underneath lists each device by name.
public enum MenuBarBattery {
    public static let separator = " · "

    /// Shown in place of the charge readings for a moment after a DPI preset
    /// change.
    public static func label(forDPI dpi: Int) -> String {
        "\(dpi) DPI"
    }

    public static func label(for battery: HIDPPBattery) -> String? {
        guard let percentage = battery.percentage else { return nil }
        return "\(percentage)%\(battery.charging ? " ⚡" : "")"
    }

    /// `readings` pairs each device's opt-in flag with its last reading, in
    /// display order. Returns an empty string when there is nothing to show
    /// so the status item collapses back to just the icon.
    public static func title(for readings: [(shown: Bool, battery: HIDPPBattery?)]) -> String {
        readings
            .filter(\.shown)
            .compactMap { $0.battery.flatMap(label(for:)) }
            .joined(separator: separator)
    }
}
