// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import HIDPP
import LoLiCore
import SwiftUI

/// Button remapping, including the two buttons macOS cannot see by itself.
struct ButtonsSection: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.device.supportsHardwareSettings, model.supports(\.buttonDiversion) {
                wheelModeButton
                thumbButton
            }
            ordinaryButtons
        }
    }

    // MARK: - Wheel-mode button

    private var wheelModeButton: some View {
        SettingsSection(
            title: "Wheel-mode button",
            subtitle: "The small button just below the scroll wheel."
        ) {
            ManagedSetting(
                title: "Take over this button",
                help: "While this is off the button keeps its factory job of toggling the wheel "
                    + "ratchet, handled inside the mouse.",
                isManaged: model.enabled(\.buttons.wheelModeButton)
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ActionPicker(label: "Press", action: model.value(\.buttons.wheelModeButton))
                        .frame(width: 320)

                    if case .cycleDPIPresets = model.configuration.buttons.wheelModeButton.value {
                        Text("Remember to switch DPI presets on in the Pointer tab, otherwise there "
                            + "is nothing to cycle through.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Thumb button

    private var thumbButton: some View {
        SettingsSection(
            title: "Thumb button",
            subtitle: "The button under the thumb rest."
        ) {
            ManagedSetting(
                title: "Action on press",
                help: "What a plain press does. Leave the gestures below switched off to make this "
                    + "an ordinary extra button.",
                isManaged: model.enabled(\.buttons.thumbButton.tap)
            ) {
                ActionPicker(label: "Press", action: model.value(\.buttons.thumbButton.tap))
                    .frame(width: 320)
            }

            Divider()

            ManagedSetting(
                title: "Flick gestures",
                help: "Hold the button and move the mouse. Switch this off and the button stops "
                    + "caring about movement entirely.",
                isManaged: model.enabled(\.buttons.thumbButton.gestures)
            ) {
                gestureEditor
            }
        }
    }

    @ViewBuilder
    private var gestureEditor: some View {
        let gestures = model.value(\.buttons.thumbButton.gestures)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(GestureDirection.allCases, id: \.self) { direction in
                HStack {
                    Text(direction.displayName)
                        .frame(width: 90, alignment: .leading)
                    ActionPicker(
                        label: "",
                        action: Binding(
                            get: { gestures.wrappedValue[direction] ?? .none },
                            set: { newValue in
                                var updated = gestures.wrappedValue
                                updated[direction] = newValue
                                gestures.wrappedValue = updated
                            }
                        )
                    )
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            LabelledSlider(
                label: "Flick distance",
                value: model.binding(\.buttons.thumbButton.threshold),
                range: 20 ... 200,
                step: 5,
                format: { String(format: "%.0f", $0) }
            )
        }
    }

    // MARK: - Ordinary buttons

    private var ordinaryButtons: some View {
        SettingsSection(
            title: "Other buttons",
            subtitle: "Buttons that arrive as ordinary macOS mouse events."
        ) {
            ManagedSetting(
                title: "Remap buttons",
                isManaged: model.enabled(\.buttons.mappings)
            ) {
                mappingEditor
            }
        }
    }

    @ViewBuilder
    private var mappingEditor: some View {
        let mappings = model.value(\.buttons.mappings)

        VStack(alignment: .leading, spacing: 8) {
            if mappings.wrappedValue.isEmpty {
                Text("No buttons remapped yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(mappings.wrappedValue.enumerated()), id: \.element.id) { index, mapping in
                HStack {
                    Stepper(value: Binding(
                        get: { mapping.button },
                        set: { newValue in
                            var updated = mappings.wrappedValue
                            updated[index].button = newValue
                            mappings.wrappedValue = updated
                        }
                    ), in: 2 ... 31) {
                        Text("Button \(mapping.button + 1)")
                            .frame(width: 90, alignment: .leading)
                    }

                    ActionPicker(label: "", action: Binding(
                        get: { mapping.action },
                        set: { newValue in
                            var updated = mappings.wrappedValue
                            updated[index].action = newValue
                            mappings.wrappedValue = updated
                        }
                    ))
                    .labelsHidden()
                    .frame(width: 240)

                    Button {
                        var updated = mappings.wrappedValue
                        updated.remove(at: index)
                        mappings.wrappedValue = updated
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                var updated = mappings.wrappedValue
                updated.append(ButtonMapping(button: 3, action: .back))
                mappings.wrappedValue = updated
            } label: {
                Label("Add mapping", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text("Left, right and the standard back and forward buttons are left alone on purpose — "
                + "macOS already handles them correctly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
