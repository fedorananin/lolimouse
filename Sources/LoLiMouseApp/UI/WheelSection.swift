// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

/// The wheel's physical behaviour, all of it living in the mouse's firmware.
struct WheelSection: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.device.supportsHardwareSettings {
                UnsupportedNotice()
            } else {
                if supports(\.smartShift) {
                    SettingsSection(
                        title: "Ratchet",
                        subtitle: "How the wheel feels, set in the mouse itself."
                    ) {
                        ManagedSetting(
                            title: "Control the wheel ratchet",
                            help: "While this is off the mouse keeps whatever ratchet behaviour it already had, "
                                + "including anything Logitech's own software set.",
                            isManaged: model.enabled(\.hardware.wheelRatchet)
                        ) {
                            ratchetControls
                        }
                    }
                }

                if supports(\.hiResWheel) {
                    SettingsSection(
                        title: "Resolution",
                        subtitle: "How many scroll events one physical click produces."
                    ) {
                        ManagedSetting(
                            title: "Control high-resolution scrolling",
                            help: "High resolution makes scrolling smooth, but sends eight or more events per "
                                + "click — which is why some galleries and carousels jump several items at once.",
                            isManaged: model.enabled(\.hardware.highResolutionWheel)
                        ) {
                            Picker("Wheel reports", selection: model.value(\.hardware.highResolutionWheel)) {
                                Text("One event per click").tag(false)
                                Text("High resolution").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                        }

                        if supports(\.wheelInvert) {
                            Divider()

                            ManagedSetting(
                                title: "Invert scrolling in the firmware",
                                help: "Reverses direction inside the mouse. Usually you want the software option "
                                    + "on the Scrolling tab instead; this one also affects other computers the "
                                    + "mouse is paired with.",
                                isManaged: model.enabled(\.hardware.invertScrollInFirmware)
                            ) {
                                Toggle("Inverted", isOn: model.value(\.hardware.invertScrollInFirmware))
                            }
                        }
                    }
                }

                if !supports(\.smartShift), !supports(\.hiResWheel) {
                    ContentUnavailableMessage(
                        title: "No wheel settings",
                        message: "This device's firmware does not expose any wheel behaviour to control."
                    )
                }
            }
        }
    }

    private func supports(_ capability: KeyPath<DeviceCapabilities, Bool>) -> Bool {
        model.supports(capability)
    }

    @ViewBuilder
    private var ratchetControls: some View {
        let mode = model.binding(\.hardware.wheelRatchet.value.mode)

        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: mode) {
                ForEach(WheelRatchetMode.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            Text(explanation(for: mode.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if mode.wrappedValue == .smartShift {
                LabelledSlider(
                    label: "Release above",
                    value: Binding(
                        get: { Double(model.configuration.hardware.wheelRatchet.value.threshold) },
                        set: { model.binding(\.hardware.wheelRatchet.value.threshold).wrappedValue = Int($0) }
                    ),
                    range: Double(WheelRatchetSetting.minimumThreshold)
                        ... Double(WheelRatchetSetting.maximumThreshold),
                    step: 1,
                    format: { String(format: "%.0f", $0 / 4) + " turns/s" }
                )
            }
        }
    }

    private func explanation(for mode: WheelRatchetMode) -> String {
        switch mode {
        case .alwaysRatchet:
            return "The wheel always clicks. It will never slip into free spin, no matter how hard "
                + "you flick it — this is the setting Logitech's own software does not offer."
        case .smartShift:
            return "The wheel clicks normally and releases into free spin once you spin it faster "
                + "than the threshold below."
        case .freeSpin:
            return "The wheel always spins freely, with no clicks."
        }
    }
}

struct UnsupportedNotice: View {
    var body: some View {
        Label(
            "This device does not speak Logitech HID++, so its firmware settings cannot be changed. "
                + "Scrolling, pointer and button settings still work.",
            systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
