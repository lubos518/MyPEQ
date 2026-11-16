//  ContentView.swift
//  Distilled, audiophile-grade Liquid Glass interface for MyPEQ with multi-profile stacking
//  and live EqualizerAPO filter authoring.

import SwiftUI
import UniformTypeIdentifiers

private struct FilterEditorTarget: Identifiable {
    let id = UUID()
    let profileID: UUID
    let profileName: String
    let existingBand: EQBand?
    let initialBand: EQBand
}

public struct ContentView: View {
    @ObservedObject private var audioEngine = PEQAudioEngine.shared
    @ObservedObject private var profileStore = ProfileStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var isFileImporterPresented = false
    @State private var pendingReplaceProfileID: UUID?

    @State private var isNewCustomAlertPresented = false
    @State private var newCustomNameDraft = ""

    @State private var renamingProfile: EQProfile?
    @State private var renameDraft: String = ""

    @State private var keywordEditingProfile: EQProfile?
    @State private var keywordDraft: String = ""

    @State private var deletingProfile: EQProfile?
    @State private var filterEditorTarget: FilterEditorTarget?
    @State private var errorAlertMessage: String?

    private var importContentTypes: [UTType] {
        [.plainText, .text, .item]
    }

    public init() {}

    public var body: some View {
        ZStack {
            LiquidGlassBackground()

            ScrollView {
                VStack(spacing: 18) {
                    savedProfilesSection

                    FrequencyResponseGraph(
                        profile: profileStore.combinedActiveProfile,
                        sampleRate: audioEngine.sampleRate,
                        isMasterEnabled: audioEngine.isMasterEnabled,
                        stackedProfileCount: profileStore.activeProfiles.count
                    )

                    if let inspectedProfile = profileStore.selectedProfile {
                        preampControlCard(profile: inspectedProfile)
                        filterInspectorCard(profile: inspectedProfile)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            floatingHeaderBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: profileStore.activeProfileIDs
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: profileStore.selectedProfileID
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: audioEngine.isMasterEnabled
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(item: $filterEditorTarget) { target in
            FilterEditorSheet(
                target: target,
                onSave: { updatedBand in
                    if target.existingBand != nil {
                        profileStore.updateBand(in: target.profileID, band: updatedBand)
                    } else {
                        profileStore.addBand(to: target.profileID, band: updatedBand)
                    }
                },
                onDelete: target.existingBand.map { band in
                    {
                        profileStore.deleteBand(in: target.profileID, bandID: band.id)
                    }
                }
            )
        }
        .alert("New Custom Profile", isPresented: $isNewCustomAlertPresented) {
            TextField("e.g. Bass Boost", text: $newCustomNameDraft)
            Button("Create") {
                profileStore.createBlankProfile(name: newCustomNameDraft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create an empty slot you can stack alongside headphone EQ profiles.")
        }
        .alert(
            "Rename Profile",
            isPresented: Binding(
                get: { renamingProfile != nil },
                set: { if !$0 { renamingProfile = nil } }
            ),
            presenting: renamingProfile
        ) { profile in
            TextField("Profile Name", text: $renameDraft)
            Button("Save") {
                profileStore.renameProfile(id: profile.id, newName: renameDraft)
                renamingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                renamingProfile = nil
            }
        } message: { profile in
            Text("Enter a display name for \"\(profile.name)\".")
        }
        .alert(
            "Auto-Switch Device Keyword",
            isPresented: Binding(
                get: { keywordEditingProfile != nil },
                set: { if !$0 { keywordEditingProfile = nil } }
            ),
            presenting: keywordEditingProfile
        ) { profile in
            TextField("e.g. XM5 or AirPods Pro", text: $keywordDraft)
            Button("Save") {
                profileStore.setAutoSwitchKeyword(for: profile.id, keyword: keywordDraft)
                keywordEditingProfile = nil
            }
            Button("Clear Rule", role: .destructive) {
                profileStore.setAutoSwitchKeyword(for: profile.id, keyword: nil)
                keywordEditingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                keywordEditingProfile = nil
            }
        } message: { profile in
            Text("Comma-separated Bluetooth/headphone name matches for \"\(profile.name)\".")
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingProfile
        ) { profile in
            Button("Delete \"\(profile.name)\"", role: .destructive) {
                profileStore.deleteProfile(id: profile.id)
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                deletingProfile = nil
            }
        } message: { _ in
            Text("This removes the saved EqualizerAPO slot from MyPEQ.")
        }
        .alert(
            "Notice",
            isPresented: Binding(
                get: { errorAlertMessage != nil || profileStore.lastErrorMessage != nil },
                set: {
                    if !$0 {
                        errorAlertMessage = nil
                        profileStore.lastErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                errorAlertMessage = nil
                profileStore.lastErrorMessage = nil
            }
        } message: {
            Text(errorAlertMessage ?? profileStore.lastErrorMessage ?? "")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: audioEngine.isMasterEnabled)
        .sensoryFeedback(.selection, trigger: profileStore.activeProfileIDs)
    }

    // MARK: - Header & Master Status Bar

    private var floatingHeaderBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusBadgeColor.opacity(colorScheme == .dark ? 0.24 : 0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: audioEngine.isStreamingAudio ? "waveform" : "hifispeaker.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(statusBadgeColor)
                        .symbolEffect(.variableColor.iterative, isActive: audioEngine.isStreamingAudio && !reduceMotion)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MyPEQ")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(statusHeadline)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusBadgeColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(statusBadgeColor.opacity(0.15)))
                    }

                    Text(routeSummaryText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    AirPlayRoutePickerButton()
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())

                    Toggle(isOn: $audioEngine.isMasterEnabled) {
                        Text("Master EQ")
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .frame(minHeight: 40)
                    .accessibilityLabel("Master Equalizer")
                    .accessibilityValue(audioEngine.isMasterEnabled ? "Enabled" : "Bypassed")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if audioEngine.isLoopbackDetected {
                Label(
                    "Feedback loop prevented: select wired or Bluetooth headphones as output.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingLiquidGlassBar(cornerRadius: 24)
    }

    private var statusHeadline: String {
        if audioEngine.isLoopbackDetected {
            return "Loopback"
        }
        if audioEngine.isStreamingAudio {
            return "Streaming"
        }
        return audioEngine.isReceiverListening ? "Ready" : "Starting"
    }

    private var statusBadgeColor: Color {
        if audioEngine.isLoopbackDetected {
            return .orange
        }
        if audioEngine.isStreamingAudio {
            return .green
        }
        return audioEngine.isReceiverListening ? .accentColor : .secondary
    }

    private var routeSummaryText: String {
        let rateKHz = audioEngine.sampleRate / 1000.0
        let activeCount = profileStore.activeProfiles.count
        if !audioEngine.isMasterEnabled {
            return String(format: "%.1f kHz · Bypassed · %@", rateKHz, audioEngine.outputRouteName)
        }
        if activeCount > 1 {
            return String(format: "%.1f kHz · %d Stacked · %@", rateKHz, activeCount, audioEngine.outputRouteName)
        }
        return String(format: "%.1f kHz · %@", rateKHz, audioEngine.outputRouteName)
    }

    // MARK: - Saved Profile Slots (Multi-Profile Stacking)

    private var savedProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Profiles", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Button {
                    profileStore.isAutoSwitchEnabled.toggle()
                } label: {
                    Label("Auto", systemImage: "headphones")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(profileStore.isAutoSwitchEnabled ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                profileStore.isAutoSwitchEnabled
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.primary.opacity(0.07)
                            )
                        )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Auto-switch profile by headphones")
                .accessibilityValue(profileStore.isAutoSwitchEnabled ? "On" : "Off")

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Button {
                        newCustomNameDraft = suggestedCustomSlotName()
                        isNewCustomAlertPresented = true
                    } label: {
                        Label("Custom", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)

                    Button {
                        pendingReplaceProfileID = nil
                        isFileImporterPresented = true
                    } label: {
                        Label("Import .txt", systemImage: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 16)

            if profileStore.profiles.isEmpty {
                emptySlotsCard
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(profileStore.profiles) { profile in
                            profileSlotCard(profile)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollClipDisabled()
            }
        }
        .padding(.vertical, 16)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .liquidGlassCard(cornerRadius: 24)
    }

    private func suggestedCustomSlotName() -> String {
        let existingCount = profileStore.profiles.filter {
            $0.name.localizedCaseInsensitiveContains("Custom")
        }.count
        return existingCount == 0 ? "Custom Slot" : "Custom Slot \(existingCount + 1)"
    }

    private var emptySlotsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No Profiles Yet")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Import squig.link / EqualizerAPO .txt files or create custom slots. Multiple profiles can be toggled Active at the same time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    pendingReplaceProfileID = nil
                    isFileImporterPresented = true
                } label: {
                    Label("Import .txt", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    newCustomNameDraft = "Bass Boost"
                    isNewCustomAlertPresented = true
                } label: {
                    Label("New Custom", systemImage: "plus")
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func profileSlotCard(_ profile: EQProfile) -> some View {
        let isActive = profileStore.isProfileActive(profile.id)
        let isEditing = profileStore.selectedProfile?.id == profile.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    profileStore.toggleProfileActive(id: profile.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.semibold))
                        Text(isActive ? "Active" : "Off")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(
                            isActive
                                ? Color.accentColor.opacity(0.16)
                                : Color.primary.opacity(0.07)
                        )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isActive ? "Deactivate \(profile.name) from stack" : "Activate \(profile.name) in stack")

                Spacer(minLength: 4)

                if isEditing {
                    Text("Editing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Menu {
                    slotMenuActions(for: profile)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Profile options for \(profile.name)")
            }

            Button {
                profileStore.selectProfileForEditing(id: profile.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)

                    HStack(spacing: 6) {
                        Text(String(format: "%+.1f dB", profile.preampDB))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(
                                    isActive
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.primary.opacity(0.07)
                                )
                            )

                        Text("\(profile.enabledBandCount)/\(profile.bands.count)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 2)

                        if let matchLabel = profileStore.effectiveAutoMatchLabel(for: profile) {
                            Label(matchLabel, systemImage: "headphones")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 192, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18, isHighlighted: isActive || isEditing)
        .contextMenu {
            slotMenuActions(for: profile)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func slotMenuActions(for profile: EQProfile) -> some View {
        Button {
            profileStore.activateOnlyProfile(id: profile.id)
        } label: {
            Label("Use Only This (Solo)", systemImage: "scope")
        }

        Button {
            profileStore.selectProfileForEditing(id: profile.id)
            presentNewFilterSheet(for: profile)
        } label: {
            Label("Add Filter", systemImage: "plus.circle")
        }

        Divider()

        if !audioEngine.isLoopbackDetected,
           !audioEngine.outputRouteName.isEmpty,
           audioEngine.outputRouteName != "No Output" {
            Button {
                profileStore.setAutoSwitchKeyword(for: profile.id, keyword: audioEngine.outputRouteName)
            } label: {
                Label("Link to \"\(audioEngine.outputRouteName)\"", systemImage: "headphones")
            }
        }

        Button {
            keywordDraft = profile.autoSwitchKeyword ?? profileStore.effectiveAutoMatchLabel(for: profile) ?? ""
            keywordEditingProfile = profile
        } label: {
            Label("Set Auto-Switch Keyword…", systemImage: "tag")
        }

        if profile.autoSwitchKeyword != nil {
            Button {
                profileStore.setAutoSwitchKeyword(for: profile.id, keyword: nil)
            } label: {
                Label("Clear Auto-Switch Link", systemImage: "tag.slash")
            }
        }

        Divider()

        Button {
            renameDraft = profile.name
            renamingProfile = profile
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            pendingReplaceProfileID = profile.id
            isFileImporterPresented = true
        } label: {
            Label("Replace .txt File", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
        }

        Divider()

        Button(role: .destructive) {
            deletingProfile = profile
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Preamp Card

    private func preampControlCard(profile: EQProfile) -> some View {
        let combinedPreamp = profileStore.combinedActiveProfile?.preampDB ?? 0.0
        let showCombinedNote = profileStore.activeProfiles.count > 1 && profileStore.isProfileActive(profile.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Preamp Gain", systemImage: "dial.medium")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(profile.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(String(format: "%+.1f dB", profile.preampDB))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(preampTint(for: profile.preampDB))
            }

            if showCombinedNote {
                Text(String(format: "Combined stack total preamp: %+.1f dB", combinedPreamp))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(profile.preampDB) },
                    set: { profileStore.setPreamp(for: profile.id, db: Float($0)) }
                ),
                in: -20.0...20.0,
                step: 0.1
            ) {
                Text("Preamp Gain")
            } minimumValueLabel: {
                Text("-20")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+20")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .tint(preampTint(for: profile.preampDB))
            .accessibilityLabel("Preamp gain in decibels for \(profile.name)")
            .accessibilityValue(String(format: "%+.1f dB", profile.preampDB))

            HStack(spacing: 10) {
                Button {
                    profileStore.stepPreamp(for: profile.id, by: -0.1)
                } label: {
                    Label("-0.1 dB", systemImage: "minus")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(profile.preampDB <= -19.99)

                Button {
                    profileStore.setPreamp(for: profile.id, db: 0.0)
                } label: {
                    Text("0.0 dB")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 72, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(abs(profile.preampDB) < 0.05)

                Button {
                    profileStore.stepPreamp(for: profile.id, by: 0.1)
                } label: {
                    Label("+0.1 dB", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(profile.preampDB >= 19.99)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
        .sensoryFeedback(.selection, trigger: profile.preampDB)
    }

    private func preampTint(for db: Float) -> Color {
        if db > 0.05 { return .orange }
        if db < -0.05 { return .accentColor }
        return .secondary
    }

    // MARK: - Parametric Filter Inspector & Editor

    private func filterInspectorCard(profile: EQProfile) -> some View {
        let totalActiveEnabled = profileStore.combinedActiveProfile?.enabledBandCount ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("· \(profile.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(profile.enabledBandCount)/\(profile.bands.count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    presentNewFilterSheet(for: profile)
                } label: {
                    Label("Add Filter", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }

            if totalActiveEnabled > APOParser.maxHardwareBands {
                Label(
                    "Active stack has \(totalActiveEnabled) filters; AVAudioUnitEQ applies the first \(APOParser.maxHardwareBands).",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if profile.bands.isEmpty {
                emptyFiltersQuickAdd(for: profile)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(profile.bands.enumerated()), id: \.element.id) { index, band in
                        filterRow(profile: profile, index: index, band: band)
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func emptyFiltersQuickAdd(for profile: EQProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No filters in \"\(profile.name)\" yet. Add a custom filter or start from a quick shelf:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    let bassShelf = EQBand(frequency: 105.0, gain: 4.0, q: 0.71, type: .lsc, isEnabled: true)
                    profileStore.addBand(to: profile.id, band: bassShelf)
                } label: {
                    Label("Low Shelf", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)

                Button {
                    let peak = EQBand(frequency: 1000.0, gain: 2.0, q: 1.41, type: .pk, isEnabled: true)
                    profileStore.addBand(to: profile.id, band: peak)
                } label: {
                    Label("Peaking", systemImage: "dial.low")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)

                Button {
                    let highShelf = EQBand(frequency: 8000.0, gain: 2.0, q: 0.71, type: .hsc, isEnabled: true)
                    profileStore.addBand(to: profile.id, band: highShelf)
                } label: {
                    Label("High Shelf", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func filterRow(profile: EQProfile, index: Int, band: EQBand) -> some View {
        let isProfileActive = profileStore.isProfileActive(profile.id)
        let isEffective = band.isEnabled && isProfileActive && audioEngine.isMasterEnabled
        let gainColor: Color = !isEffective
            ? .secondary
            : (band.gain > 0.05 ? .orange : (band.gain < -0.05 ? .cyan : .secondary))
        let gainSymbol = band.gain > 0.05 ? "arrow.up" : (band.gain < -0.05 ? "arrow.down" : "minus")

        return HStack(spacing: 8) {
            Button {
                filterEditorTarget = FilterEditorTarget(
                    profileID: profile.id,
                    profileName: profile.name,
                    existingBand: band,
                    initialBand: band
                )
            } label: {
                HStack(spacing: 10) {
                    Text(band.type.shortLabel)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isEffective ? Color.accentColor : Color.secondary)
                        .frame(width: 38, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isEffective ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                        )
                        .accessibilityLabel(band.type.accessibleName)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatFrequency(band.frequency))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isEffective ? Color.primary : Color.secondary)

                        HStack(spacing: 6) {
                            Text(String(format: "Q %.2f", band.q))
                            Text(String(format: "BW %.2f", APOParser.bandwidthInOctaves(fromQ: band.q)))
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Image(systemName: gainSymbol)
                            .font(.caption2.weight(.bold))
                        Text(String(format: "%+.1f dB", band.gain))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(gainColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tap to edit frequency, gain, Q, and filter type")

            Toggle(isOn: Binding(
                get: { band.isEnabled },
                set: { _ in
                    profileStore.toggleBand(profileID: profile.id, bandID: band.id)
                }
            )) {
                Text("Enable Band \(index + 1)")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.accentColor)
            .accessibilityLabel("Filter \(index + 1), \(band.type.accessibleName) at \(formatFrequency(band.frequency))")

            Button(role: .destructive) {
                profileStore.deleteBand(in: profile.id, bandID: band.id)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete filter at \(formatFrequency(band.frequency))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .opacity(band.isEnabled ? 1.0 : 0.62)
        .contextMenu {
            Button {
                filterEditorTarget = FilterEditorTarget(
                    profileID: profile.id,
                    profileName: profile.name,
                    existingBand: band,
                    initialBand: band
                )
            } label: {
                Label("Edit Filter", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                profileStore.deleteBand(in: profile.id, bandID: band.id)
            } label: {
                Label("Delete Filter", systemImage: "trash")
            }
        }
        .sensoryFeedback(.selection, trigger: band.isEnabled)
    }

    private func presentNewFilterSheet(for profile: EQProfile) {
        let defaultBand = EQBand(frequency: 105.0, gain: 3.0, q: 0.71, type: .lsc, isEnabled: true)
        filterEditorTarget = FilterEditorTarget(
            profileID: profile.id,
            profileName: profile.name,
            existingBand: nil,
            initialBand: defaultBand
        )
    }

    private func formatFrequency(_ hz: Float) -> String {
        if hz >= 1000.0 {
            let kHz = hz / 1000.0
            if abs(kHz.rounded() - kHz) < 0.05 {
                return String(format: "%.0f kHz", kHz)
            }
            return String(format: "%.2f kHz", kHz)
        }
        if abs(hz.rounded() - hz) < 0.05 {
            return String(format: "%.0f Hz", hz)
        }
        return String(format: "%.1f Hz", hz)
    }

    // MARK: - File Import Handler

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let targetReplaceID = pendingReplaceProfileID
        pendingReplaceProfileID = nil

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                if let targetReplaceID {
                    try profileStore.replaceProfile(id: targetReplaceID, withFileURL: url)
                } else {
                    try profileStore.importFromFileURL(url)
                }
            } catch {
                errorAlertMessage = error.localizedDescription
            }

        case .failure(let error):
            errorAlertMessage = error.localizedDescription
        }
    }
}

// MARK: - Filter Editor Sheet

private struct FilterEditorSheet: View {
    let target: FilterEditorTarget
    let onSave: (EQBand) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var type: EQFilterType
    @State private var frequency: Float
    @State private var gain: Float
    @State private var q: Float
    @State private var isEnabled: Bool

    private let minLogFreq = log10(20.0)
    private let maxLogFreq = log10(20000.0)

    init(
        target: FilterEditorTarget,
        onSave: @escaping (EQBand) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.target = target
        self.onSave = onSave
        self.onDelete = onDelete
        _type = State(initialValue: target.initialBand.type)
        _frequency = State(initialValue: target.initialBand.frequency)
        _gain = State(initialValue: target.initialBand.gain)
        _q = State(initialValue: target.initialBand.q)
        _isEnabled = State(initialValue: target.initialBand.isEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Filter Type", selection: $type) {
                        ForEach(EQFilterType.allCases, id: \.self) { filterType in
                            Text("\(filterType.rawValue) · \(filterType.accessibleName)")
                                .tag(filterType)
                        }
                    }

                    Toggle("Filter Enabled", isOn: $isEnabled)
                } header: {
                    Text(target.profileName)
                }

                Section("Center Frequency") {
                    HStack {
                        Text("Frequency (Hz)")
                        Spacer()
                        TextField(
                            "Hz",
                            value: Binding(
                                get: { frequency },
                                set: { frequency = EQBand.clampFrequency($0) }
                            ),
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: 110)
                    }

                    Slider(
                        value: Binding(
                            get: { log10(Double(max(frequency, 20.0))) },
                            set: { logVal in
                                let hz = Float(pow(10.0, logVal))
                                frequency = EQBand.clampFrequency(hz < 100 ? hz.rounded() : (hz * 2.0).rounded() / 2.0)
                            }
                        ),
                        in: minLogFreq...maxLogFreq
                    )

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                        spacing: 6
                    ) {
                        ForEach([32, 60, 105, 250, 1000, 4000, 8000, 12000], id: \.self) { presetHz in
                            Button {
                                frequency = Float(presetHz)
                            } label: {
                                Text(presetHz >= 1000 ? "\(presetHz / 1000) kHz" : "\(presetHz) Hz")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .monospacedDigit()
                        }
                    }

                    HStack(spacing: 10) {
                        Button("-5 Hz") { frequency = EQBand.clampFrequency(frequency - 5) }
                            .buttonStyle(.bordered)
                        Button("-1 Hz") { frequency = EQBand.clampFrequency(frequency - 1) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("+1 Hz") { frequency = EQBand.clampFrequency(frequency + 1) }
                            .buttonStyle(.bordered)
                        Button("+5 Hz") { frequency = EQBand.clampFrequency(frequency + 5) }
                            .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }

                Section("Gain") {
                    HStack {
                        Text("Gain")
                        Spacer()
                        Text(String(format: "%+.1f dB", gain))
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(gain > 0.05 ? Color.orange : (gain < -0.05 ? Color.cyan : Color.secondary))
                    }

                    Slider(
                        value: Binding(
                            get: { Double(gain) },
                            set: { gain = Float(($0 * 10.0).rounded() / 10.0) }
                        ),
                        in: -20.0...20.0,
                        step: 0.1
                    )

                    HStack(spacing: 10) {
                        Button("-0.5 dB") { gain = EQBand.clampGain(((gain - 0.5) * 10).rounded() / 10) }
                            .buttonStyle(.bordered)
                        Button("-0.1 dB") { gain = EQBand.clampGain(((gain - 0.1) * 10).rounded() / 10) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("+0.1 dB") { gain = EQBand.clampGain(((gain + 0.1) * 10).rounded() / 10) }
                            .buttonStyle(.bordered)
                        Button("+0.5 dB") { gain = EQBand.clampGain(((gain + 0.5) * 10).rounded() / 10) }
                            .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }

                Section("Q Factor & Bandwidth") {
                    HStack {
                        Text(String(format: "Q %.2f", q))
                            .font(.headline)
                            .monospacedDigit()
                        Spacer()
                        Text(String(format: "BW %.2f oct", APOParser.bandwidthInOctaves(fromQ: q)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(q) },
                            set: { q = EQBand.clampQ(Float(($0 * 100.0).rounded() / 100.0)) }
                        ),
                        in: 0.10...10.0,
                        step: 0.01
                    )

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                        spacing: 6
                    ) {
                        ForEach([0.50, 0.71, 1.00, 1.41, 2.00, 4.00], id: \.self) { presetQ in
                            Button {
                                q = Float(presetQ)
                            } label: {
                                Text(String(format: "Q %.2f", presetQ))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .monospacedDigit()
                        }
                    }

                    HStack(spacing: 10) {
                        Button("-0.05") { q = EQBand.clampQ(((q - 0.05) * 100).rounded() / 100) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("+0.05") { q = EQBand.clampQ(((q + 0.05) * 100).rounded() / 100) }
                            .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }

                if let onDelete {
                    Section {
                        Button("Delete Filter", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(target.existingBand == nil ? "Add Filter" : "Edit Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.existingBand == nil ? "Add" : "Save") {
                        let result = EQBand(
                            id: target.existingBand?.id ?? UUID(),
                            frequency: frequency,
                            gain: gain,
                            q: q,
                            type: type,
                            isEnabled: isEnabled
                        )
                        onSave(result)
                        dismiss()
                    }
                }
            }
        }
    }
}
