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
        load()
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
            importedAt: Date()
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
