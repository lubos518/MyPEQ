//  ProfileStore.swift
//  Persistent multi-profile storage, stack merging, and filter editing in Documents.

import Combine
import Foundation
import os

@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public private(set) var profiles: [EQProfile] = []
    @Published public private(set) var activeProfileIDs: Set<UUID> = []
    @Published public private(set) var selectedProfileID: UUID?
    @Published public var lastErrorMessage: String?

    @Published public var isAutoSwitchEnabled: Bool = true {
        didSet {
            guard isInitialized else { return }
            UserDefaults.standard.set(isAutoSwitchEnabled, forKey: Self.autoSwitchDefaultsKey)
            if isAutoSwitchEnabled {
                lastAutoRoutedDeviceName = nil
                handleOutputRouteChanged(
                    routeName: PEQAudioEngine.shared.outputRouteName,
                    isHeadphoneRoute: PEQAudioEngine.shared.isHeadphoneConnected
                )
            }
        }
    }

    private static let autoSwitchDefaultsKey = "com.mypeq.autoSwitchEnabled"
    private var lastAutoRoutedDeviceName: String?
    private var isInitialized = false

    /// The profile currently inspected in the Preamp & Filter Editor cards.
    public var selectedProfile: EQProfile? {
        if let selectedProfileID,
           let match = profiles.first(where: { $0.id == selectedProfileID }) {
            return match
        }
        return profiles.first
    }

    /// All profiles enabled in the active processing stack, preserving card order.
    public var activeProfiles: [EQProfile] {
        profiles.filter { activeProfileIDs.contains($0.id) }
    }

    /// Combined EqualizerAPO curve & Preamp sent to PEQAudioEngine and the Frequency Response graph.
    public var combinedActiveProfile: EQProfile? {
        let active = activeProfiles
        guard !active.isEmpty else { return nil }
        if active.count == 1, let single = active.first {
            return single
        }

        let summedPreamp = active.reduce(Float(0)) { $0 + $1.preampDB }
        let mergedBands = active.flatMap { $0.bands.filter(\.isEnabled) }
        let mergedName = active.map(\.name).joined(separator: " + ")

        return EQProfile(
            id: active[0].id,
            name: mergedName,
            preampDB: EQProfile.clampPreamp(summedPreamp),
            bands: mergedBands,
            importedAt: active[0].importedAt
        )
    }

    public var activeProfile: EQProfile? {
        combinedActiveProfile
    }

    private struct PersistedStore: Codable {
        var profiles: [EQProfile]
        var activeProfileID: UUID?
        var activeProfileIDs: [UUID]?
        var selectedProfileID: UUID?
    }

    private let logger = Logger(subsystem: "com.mypeq.app", category: "profile-store")
    private let fileURL: URL

    private init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = docsDir.appendingPathComponent("MyPEQProfiles.json", isDirectory: false)
        if UserDefaults.standard.object(forKey: Self.autoSwitchDefaultsKey) != nil {
            self.isAutoSwitchEnabled = UserDefaults.standard.bool(forKey: Self.autoSwitchDefaultsKey)
        }
        load()
        isInitialized = true
    }

    public func isProfileActive(_ id: UUID) -> Bool {
        activeProfileIDs.contains(id)
    }

    @discardableResult
    public func importFromFileURL(_ url: URL) throws -> EQProfile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let rawName = url.deletingPathExtension().lastPathComponent
        let profile = try APOParser.parse(data: data, profileName: rawName)
        return insertProfile(profile, soloActivate: true)
    }

    @discardableResult
    public func importFromText(_ text: String, name: String) throws -> EQProfile {
        let profile = try APOParser.parse(text: text, profileName: name)
        return insertProfile(profile, soloActivate: true)
    }

    public func replaceProfile(id: UUID, withFileURL url: URL) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let parsed = try APOParser.parse(data: data, profileName: profiles[index].name)

        let updated = EQProfile(
            id: profiles[index].id,
            name: profiles[index].name,
            preampDB: parsed.preampDB,
            bands: parsed.bands,
            importedAt: Date(),
            autoSwitchKeyword: profiles[index].autoSwitchKeyword
        )
        profiles[index] = updated
        save()

        if activeProfileIDs.contains(id) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func createBlankProfile(name: String = "Custom Slot", initialBand: EQBand? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bands = initialBand.map { [$0] } ?? []
        let profile = EQProfile(
            name: cleanName.isEmpty ? "Custom Slot" : cleanName,
            preampDB: 0.0,
            bands: bands
        )
        insertProfile(profile, soloActivate: false)
    }

    public func toggleProfileActive(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if activeProfileIDs.contains(id) {
            activeProfileIDs.remove(id)
        } else {
            activeProfileIDs.insert(id)
            selectedProfileID = id
        }
        save()
        PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
    }

    public func activateOnlyProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileIDs = [id]
        selectedProfileID = id
        save()
        PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
    }

    public func selectProfileForEditing(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        if activeProfileIDs.isEmpty {
            activeProfileIDs = [id]
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
        save()
    }

    public func selectProfile(id: UUID) {
        activateOnlyProfile(id: id)
    }

    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        profiles[index].name = trimmed
        save()
        if activeProfileIDs.contains(id) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        activeProfileIDs.remove(id)

        if selectedProfileID == id {
            if let firstActive = activeProfiles.first {
                selectedProfileID = firstActive.id
            } else if !profiles.isEmpty {
                selectedProfileID = profiles[min(index, profiles.count - 1)].id
            } else {
                selectedProfileID = nil
            }
        }

        if activeProfileIDs.isEmpty, let fallbackID = selectedProfileID {
            activeProfileIDs.insert(fallbackID)
        }

        save()
        PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
    }

    public func setPreamp(for id: UUID, db: Float) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let stepped = (EQProfile.clampPreamp(db) * 10.0).rounded() / 10.0
        profiles[index].preampDB = stepped
        save()
        if activeProfileIDs.contains(id) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func stepPreamp(for id: UUID, by delta: Float) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        setPreamp(for: id, db: profile.preampDB + delta)
    }

    public func addBand(to profileID: UUID, band: EQBand) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[profileIndex].bands.append(band)
        save()
        if activeProfileIDs.contains(profileID) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func updateBand(in profileID: UUID, band: EQBand) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let bandIndex = profiles[profileIndex].bands.firstIndex(where: { $0.id == band.id }) else {
            return
        }
        profiles[profileIndex].bands[bandIndex] = band
        save()
        if activeProfileIDs.contains(profileID) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func deleteBand(in profileID: UUID, bandID: UUID) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let bandIndex = profiles[profileIndex].bands.firstIndex(where: { $0.id == bandID }) else {
            return
        }
        profiles[profileIndex].bands.remove(at: bandIndex)
        save()
        if activeProfileIDs.contains(profileID) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    public func toggleBand(profileID: UUID, bandID: UUID) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let bandIndex = profiles[profileIndex].bands.firstIndex(where: { $0.id == bandID }) else {
            return
        }
        profiles[profileIndex].bands[bandIndex].isEnabled.toggle()
        save()
        if activeProfileIDs.contains(profileID) {
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    // MARK: - Automatic Headphone Detection & Switching

    public func setAutoSwitchKeyword(for id: UUID, keyword: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].autoSwitchKeyword = (cleaned?.isEmpty == false) ? cleaned : nil
        save()
        if isAutoSwitchEnabled {
            lastAutoRoutedDeviceName = nil
            handleOutputRouteChanged(
                routeName: PEQAudioEngine.shared.outputRouteName,
                isHeadphoneRoute: PEQAudioEngine.shared.isHeadphoneConnected
            )
        }
    }

    public func effectiveAutoMatchLabel(for profile: EQProfile) -> String? {
        if let explicit = profile.autoSwitchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        let lower = profile.name.lowercased()
        if lower.contains("xm5") {
            return "XM5"
        }
        if lower.contains("xm4") {
            return "XM4"
        }
        if lower.contains("airpods pro") || containsWordToken("ap3", in: lower) || containsWordToken("ap2", in: lower) {
            return "AirPods Pro"
        }
        if lower.contains("airpods max") {
            return "AirPods Max"
        }
        return nil
    }

    public func handleOutputRouteChanged(routeName: String, isHeadphoneRoute: Bool) {
        guard isAutoSwitchEnabled else { return }

        let trimmedRoute = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoute.isEmpty, trimmedRoute != "No Output" else { return }

        let normalizedRoute = trimmedRoute.lowercased()
        if normalizedRoute.contains("mypeq") || normalizedRoute.contains("effectdeck") {
            return
        }

        guard lastAutoRoutedDeviceName != trimmedRoute else { return }
        lastAutoRoutedDeviceName = trimmedRoute

        let matchedProfiles = profiles.filter {
            matchesRoute(profile: $0, normalizedRoute: normalizedRoute, isHeadphoneRoute: isHeadphoneRoute)
        }
        guard !matchedProfiles.isEmpty else { return }

        let matchedIDs = Set(matchedProfiles.map(\.id))

        // Replace any previously active headphone-specific profile for a different headset,
        // while keeping unlinked add-on/custom slots (e.g. Bass Boost) stacked as-is.
        var updatedActive = activeProfileIDs.filter { activeID in
            if matchedIDs.contains(activeID) {
                return true
            }
            guard let activeProfile = profiles.first(where: { $0.id == activeID }) else {
                return false
            }
            return effectiveAutoMatchLabel(for: activeProfile) == nil
        }
        updatedActive.formUnion(matchedIDs)

        let didChange = updatedActive != activeProfileIDs || selectedProfileID != matchedProfiles[0].id
        activeProfileIDs = updatedActive
        selectedProfileID = matchedProfiles[0].id

        if didChange {
            save()
            PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        }
    }

    private func matchesRoute(profile: EQProfile, normalizedRoute: String, isHeadphoneRoute: Bool) -> Bool {
        if let rawKeyword = profile.autoSwitchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawKeyword.isEmpty {
            let keywords = rawKeyword
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return keywords.contains { normalizedRoute.contains($0) }
        }

        let lowerName = profile.name.lowercased()
        if normalizedRoute.contains("xm5") {
            return lowerName.contains("xm5")
        }
        if normalizedRoute.contains("xm4") {
            return lowerName.contains("xm4")
        }
        if normalizedRoute.contains("airpods pro") {
            return lowerName.contains("airpods pro")
                || containsWordToken("ap3", in: lowerName)
                || containsWordToken("ap2", in: lowerName)
        }
        if normalizedRoute.contains("airpods max") {
            return lowerName.contains("airpods max")
        }

        if isHeadphoneRoute, normalizedRoute.count >= 4 {
            return lowerName.contains(normalizedRoute)
        }
        return false
    }

    private func containsWordToken(_ token: String, in text: String) -> Bool {
        let parts = text.split { !$0.isLetter && !$0.isNumber }
        return parts.contains { $0 == token }
    }

    // MARK: - Persistence

    @discardableResult
    private func insertProfile(_ profile: EQProfile, soloActivate: Bool) -> EQProfile {
        profiles.insert(profile, at: 0)
        if soloActivate {
            activeProfileIDs = [profile.id]
        } else {
            activeProfileIDs.insert(profile.id)
        }
        selectedProfileID = profile.id
        save()
        PEQAudioEngine.shared.apply(profile: combinedActiveProfile)
        return profile
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            activeProfileIDs = []
            selectedProfileID = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedStore.self, from: data)
            profiles = decoded.profiles
            let validIDs = Set(profiles.map(\.id))

            if let savedIDs = decoded.activeProfileIDs {
                activeProfileIDs = Set(savedIDs.filter { validIDs.contains($0) })
            } else if let legacyID = decoded.activeProfileID, validIDs.contains(legacyID) {
                activeProfileIDs = [legacyID]
            } else if let firstID = profiles.first?.id {
                activeProfileIDs = [firstID]
            } else {
                activeProfileIDs = []
            }

            if let savedSelected = decoded.selectedProfileID, validIDs.contains(savedSelected) {
                selectedProfileID = savedSelected
            } else {
                selectedProfileID = activeProfiles.first?.id ?? profiles.first?.id
            }
        } catch {
            logger.error("Failed to load profiles: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            profiles = []
            activeProfileIDs = []
            selectedProfileID = nil
        }
    }

    private func save() {
        do {
            let orderedActive = profiles.map(\.id).filter { activeProfileIDs.contains($0) }
            let payload = PersistedStore(
                profiles: profiles,
                activeProfileID: orderedActive.first,
                activeProfileIDs: orderedActive,
                selectedProfileID: selectedProfileID
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Failed to save profiles: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
        }
    }
}
