// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

/// Sensor resolution (in the mouse) and tracking behaviour (in macOS).
struct PointerSection: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.device.supportsHardwareSettings, model.supports(\.dpi) {
                SettingsSection(
                    title: "Sensor resolution",
                    subtitle: "DPI, written into the mouse itself."
                ) {
                    ManagedSetting(
                        title: "Set a fixed DPI",
                        isManaged: model.enabled(\.hardware.dpi)
                    ) {
                        Stepper(value: model.value(\.hardware.dpi), in: 200 ... 8000, step: 50) {
                            Text("\(model.configuration.hardware.dpi.value) DPI")
                        }
                        .frame(width: 240)
                    }

                    Divider()

                    ManagedSetting(
                        title: "DPI presets",
                        help: "Bind “Cycle DPI presets” to a button — the wheel-mode button is the "
                            + "natural home for it — and each press steps to the next value.",
                        isManaged: model.enabled(\.hardware.dpiPresets)
                    ) {
                        DPIPresetEditor(model: model)
                    }
                }
            }

            SettingsSection(
                title: "Tracking",
                subtitle: "How macOS translates sensor movement into cursor movement, for this mouse only."
            ) {
                ManagedSetting(
                    title: "Tracking speed",
                    isManaged: model.enabled(\.pointer.speed)
                ) {
                    LabelledSlider(
                        label: "Speed",
                        value: model.value(\.pointer.speed),
                        range: 0 ... 1,
                        step: 0.01,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                }

                Divider()

                ManagedSetting(
                    title: "Turn acceleration off",
                    help: "One-to-one tracking: the cursor moves the same distance whether you move "
                        + "the mouse slowly or quickly.",
                    isManaged: model.enabled(\.pointer.disableAcceleration)
                ) {
                    Toggle("Disabled", isOn: model.value(\.pointer.disableAcceleration))
                }

                Divider()

                ManagedSetting(
                    title: "Acceleration curve",
                    help: "Ignored while acceleration is turned off above.",
                    isManaged: model.enabled(\.pointer.acceleration)
                ) {
                    LabelledSlider(
                        label: "Strength",
                        value: model.value(\.pointer.acceleration),
                        range: 0 ... 20,
                        step: 0.5,
                        format: { String(format: "%.1f", $0) }
                    )
                }
            }

            if model.device.supportsHardwareSettings, model.supports(\.reportRate) {
                SettingsSection(title: "Report rate") {
                    ManagedSetting(
                        title: "Set the report rate",
                        help: "How often the mouse reports its position. 1 ms is 1000 Hz.",
                        isManaged: model.enabled(\.hardware.reportRate)
                    ) {
                        Picker("Interval", selection: model.value(\.hardware.reportRate)) {
                            Text("1 ms (1000 Hz)").tag(1)
                            Text("2 ms (500 Hz)").tag(2)
                            Text("4 ms (250 Hz)").tag(4)
                            Text("8 ms (125 Hz)").tag(8)
                        }
                        .frame(width: 240)
                    }
                }
            }
        }
    }
}

private struct DPIPresetEditor: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        let presets = model.value(\.hardware.dpiPresets)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(presets.wrappedValue.values.enumerated()), id: \.offset) { index, value in
                HStack {
                    Image(systemName: presets.wrappedValue.activeIndex == index
                        ? "largecircle.fill.circle"
                        : "circle")
                        .foregroundStyle(presets.wrappedValue.activeIndex == index ? Color.accentColor : .secondary)
                        .onTapGesture { presets.wrappedValue.activeIndex = index }

                    Stepper(value: Binding(
                        get: { value },
                        set: { newValue in
                            var updated = presets.wrappedValue
                            updated.values[index] = newValue
                            presets.wrappedValue = updated
                        }
                    ), in: 200 ... 8000, step: 50) {
                        Text("\(value) DPI")
                    }

                    Button {
                        var updated = presets.wrappedValue
                        updated.values.remove(at: index)
                        updated.activeIndex = min(updated.activeIndex, max(updated.values.count - 1, 0))
                        presets.wrappedValue = updated
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(presets.wrappedValue.values.count <= 1)
                }
            }

            Button {
                var updated = presets.wrappedValue
                updated.values.append(updated.values.last ?? 1000)
                presets.wrappedValue = updated
            } label: {
                Label("Add preset", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .frame(width: 300, alignment: .leading)
    }
}
