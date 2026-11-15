//  ContentView.swift
//  Distilled, audiophile-grade Liquid Glass interface for MyPEQ.

import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject private var audioEngine = PEQAudioEngine.shared
    @ObservedObject private var profileStore = ProfileStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var isFileImporterPresented = false
    @State private var pendingReplaceProfileID: UUID?

    @State private var renamingProfile: EQProfile?
    @State private var renameDraft: String = ""

    @State private var deletingProfile: EQProfile?
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
                        profile: profileStore.activeProfile,
                        sampleRate: audioEngine.sampleRate,
                        isMasterEnabled: audioEngine.isMasterEnabled
                    )

                    if let activeProfile = profileStore.activeProfile {
                        preampControlCard(profile: activeProfile)
                        filterInspectorCard(profile: activeProfile)
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
            value: profileStore.activeProfileID
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
        .sensoryFeedback(.selection, trigger: profileStore.activeProfileID)
    }

    // MARK: - Header & Master Status Bar

    private var floatingHeaderBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusBadgeColor.opacity(colorScheme == .dark ? 0.24 : 0.14))
                        .frame(width: 40, height: 40)

                    Image(systemName: audioEngine.isStreamingAudio ? "waveform" : "hifispeaker.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusBadgeColor)
                        .symbolEffect(.variableColor.iterative, isActive: audioEngine.isStreamingAudio && !reduceMotion)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MyPEQ")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)

                        Text(statusHeadline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusBadgeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(statusBadgeColor.opacity(0.14)))
                    }

                    Text(routeSummaryText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                AirPlayRoutePickerButton()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())

                Toggle(isOn: $audioEngine.isMasterEnabled) {
                    Text("Master EQ")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
                .frame(minHeight: 44)
                .accessibilityLabel("Master Equalizer")
                .accessibilityValue(audioEngine.isMasterEnabled ? "Enabled" : "Bypassed")
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
            return "Loopback Guard"
        }
        if audioEngine.isStreamingAudio {
            return "Streaming Audio"
        }
        return audioEngine.isReceiverListening ? "MyPEQ Ready" : "Starting Receiver"
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
        let bypassTag = audioEngine.isMasterEnabled ? "Float32" : "Bypassed"
        return String(format: "%.1f kHz %@ · %@", rateKHz, bypassTag, audioEngine.outputRouteName)
    }

    // MARK: - Saved Profile Slots

    private var savedProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("EqualizerAPO Profiles", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    pendingReplaceProfileID = nil
                    isFileImporterPresented = true
                } label: {
                    Label("Import EqualizerAPO (.txt)", systemImage: "doc.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minHeight: 44)
            }

            if profileStore.profiles.isEmpty {
                emptySlotsCard
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(profileStore.profiles) { profile in
                            profileSlotCard(profile)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var emptySlotsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No Profiles Imported")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Import a squig.link, AutoEQ, or EqualizerAPO .txt file from your iPhone to create your first profile slot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    pendingReplaceProfileID = nil
                    isFileImporterPresented = true
                } label: {
                    Label("Choose .txt File", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    profileStore.createBlankProfile(name: "Custom Slot")
                } label: {
                    Label("Blank Slot", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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
        let isActive = profile.id == profileStore.activeProfileID

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    profileStore.selectProfile(id: profile.id)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline)
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                            .padding(.top, 1)

                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    slotMenuActions(for: profile)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Profile options for \(profile.name)")
            }

            Button {
                profileStore.selectProfile(id: profile.id)
            } label: {
                HStack(spacing: 6) {
                    Text(String(format: "Preamp %+.1f dB", profile.preampDB))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                isActive
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.primary.opacity(0.07)
                            )
                        )

                    Text("\(profile.enabledBandCount)/\(profile.bands.count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 196, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18, isHighlighted: isActive)
        .contextMenu {
            slotMenuActions(for: profile)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func slotMenuActions(for profile: EQProfile) -> some View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Preamp Gain", systemImage: "dial.medium")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(String(format: "%+.1f dB", profile.preampDB))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(preampTint(for: profile.preampDB))
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
            .accessibilityLabel("Preamp gain in decibels")
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

    // MARK: - Parametric Filter Inspector

    private func filterInspectorCard(profile: EQProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Parametric Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(profile.enabledBandCount) / \(profile.bands.count) Active")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if profile.bands.count > APOParser.maxHardwareBands {
                Label(
                    "AVAudioUnitEQ applies the first \(APOParser.maxHardwareBands) bands of \(profile.bands.count).",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if profile.bands.isEmpty {
                Text("This slot currently has no parametric filter bands.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(profile.bands.enumerated()), id: \.element.id) { index, band in
                        filterRow(profileID: profile.id, index: index, band: band)
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    private func filterRow(profileID: UUID, index: Int, band: EQBand) -> some View {
        let isEffective = band.isEnabled && audioEngine.isMasterEnabled && index < APOParser.maxHardwareBands
        let gainColor: Color = !isEffective
            ? .secondary
            : (band.gain > 0.05 ? .orange : (band.gain < -0.05 ? .cyan : .secondary))
        let gainSymbol = band.gain > 0.05 ? "arrow.up" : (band.gain < -0.05 ? "arrow.down" : "minus")

        return HStack(spacing: 10) {
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
                HStack(spacing: 8) {
                    Text(formatFrequency(band.frequency))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isEffective ? Color.primary : Color.secondary)

                    Text(String(format: "Q %.2f", band.q))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text(String(format: "BW %.2f", APOParser.bandwidthInOctaves(fromQ: band.q)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                if index >= APOParser.maxHardwareBands {
                    Text("Exceeds 20-band DSP limit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

            Toggle(isOn: Binding(
                get: { band.isEnabled },
                set: { _ in
                    profileStore.toggleBand(profileID: profileID, bandID: band.id)
                }
            )) {
                Text("Enable Band \(index + 1)")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.accentColor)
            .accessibilityLabel("Filter \(index + 1), \(band.type.accessibleName) at \(formatFrequency(band.frequency))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .opacity(band.isEnabled ? 1.0 : 0.62)
        .sensoryFeedback(.selection, trigger: band.isEnabled)
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
