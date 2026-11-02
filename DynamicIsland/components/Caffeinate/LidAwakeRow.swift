/*
 * Luoto — a fork of Atoll (DynamicIsland)
 * Copyright (C) 2026 amidamaru940 and Luoto contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Defaults
import SwiftUI

/// The look of one state, apart from where it comes from, so every state can be
/// drawn in a test.
struct LidAwakeRowContent: View {
    let title: String
    let state: LidAwakeRowState
    @Binding var isOn: Bool
    var isSwitchEnabled = true
    /// Shown once the option is on.
    var batteryFloor: Binding<Int>?
    var perform: (LidAwakeRowState.Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // Named for VoiceOver; the visible title is beside it.
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!isSwitchEnabled)
            }

            Text(state.text)
                .font(DS.Typeface.caption)
                .foregroundStyle(state.isAttention ? DS.Palette.attention : DS.Palette.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if let batteryFloor {
                floorPicker(batteryFloor)
            }

            if let button = state.button {
                Button { perform(button.action) } label: {
                    Text(button.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, height: 28))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(DS.spring, value: state)
    }

    private func floorPicker(_ floor: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(LidAwakeCopy.sleepAtBattery)
                .font(DS.Typeface.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(LidGuardConfig.batteryFloors, id: \.self) { value in
                    floorSegment(value, selected: floor.wrappedValue == value) { floor.wrappedValue = value }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.card))
        }
    }

    private func floorSegment(_ value: Int, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            Text(LidAwakeCopy.percent(value))
                .font(.system(size: 11, weight: selected ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(selected ? Color.black : DS.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(selected ? DS.Palette.attention : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LidAwakeCopy.percent(value)))
        .accessibilityHint(Text(LidAwakeCopy.sleepAtBattery))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "With the lid closed", in the Keep Awake panel and in Settings.
struct LidAwakeRow: View {
    var title = LidAwakeCopy.title
    @ObservedObject private var lid = LidAwakeController.shared
    @ObservedObject private var caffeinate = CaffeinateManager.shared
    @Default(.caffeinateWithLidClosed) private var withLidClosed
    @Default(.lidClosedBatteryFloor) private var batteryFloor

    private var state: LidAwakeRowState {
        LidAwakeRowState.resolve(.init(
            install: lid.installState,
            optionOn: withLidClosed,
            isInstalling: lid.isInstalling,
            setupOutcome: lid.setupOutcome,
            removal: lid.removal,
            isStuck: lid.isStuck,
            canInstallFromHere: LidGuardInstaller.canInstall(fromAppPath: Bundle.main.bundleURL.path),
            sessionActive: caffeinate.isActive,
            phase: lid.phase,
            lidClosed: lid.lidClosed
        ))
    }

    var body: some View {
        LidAwakeRowContent(
            title: title,
            state: state,
            isOn: Binding(
                get: { (withLidClosed && lid.installState == .current) || lid.isInstalling },
                set: { lid.setOption($0) }
            ),
            isSwitchEnabled: !lid.isInstalling && state != .moveToApplications,
            batteryFloor: withLidClosed && lid.installState == .current
                ? Binding(get: { LidGuardConfig.batteryFloors.contains(batteryFloor) ? batteryFloor : LidGuardConfig.batteryFloor }, set: { lid.setBatteryFloor($0) })
                : nil,
            perform: { action in
                switch action {
                case .install: lid.install()
                case .turnOnAgain: lid.turnOnAgain()
                case .openLoginItems: lid.openLoginItems()
                case .fixStuckSleep: lid.fixStuckSleep()
                }
            }
        )
        .onAppear { lid.refreshInstalled() }
    }
}

/// The row in Settings, and the way to take the helper off the Mac.
struct LidAwakeSettingsRows: View {
    var isFeatureOn = true
    @ObservedObject private var lid = LidAwakeController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LidAwakeRow(title: LidAwakeCopy.settingsTitle)
                .disabled(!isFeatureOn)
            // Always possible: taking it off the Mac does not depend on the feature.
            if lid.installState != .missing {
                Button(LidAwakeCopy.removeHelper) { lid.removeHelper() }
            }
        }
    }
}
