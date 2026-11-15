//  ProfileStore.swift
//  Persistent storage and management of EqualizerAPO profile slots in the Documents directory.

import Combine
import Foundation
import os

@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public private(set) var profiles: [EQProfile] = []
    @Published public private(set) var activeProfileID: UUID?
    @Published public var lastErrorMessage: String?

    public var activeProfile: EQProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    private struct PersistedStore: Codable {
        var profiles: [EQProfile]
        var activeProfileID: UUID?
    }

    private let logger = Logger(subsystem: "com.mypeq.app", category: "profile-store")
    private let fileURL: URL

    private init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = docsDir.appendingPathComponent("MyPEQProfiles.json", isDirectory: false)
        load()
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
        return appendAndActivate(profile)
    }

    @discardableResult
    public func importFromText(_ text: String, name: String) throws -> EQProfile {
        let profile = try APOParser.parse(text: text, profileName: name)
        return appendAndActivate(profile)
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

        if activeProfileID == id {
            PEQAudioEngine.shared.apply(profile: updated)
        }
    }

    public func createBlankProfile(name: String = "Custom Profile") {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = EQProfile(
            name: cleanName.isEmpty ? "Custom Profile" : cleanName,
            preampDB: 0.0,
            bands: []
        )
        appendAndActivate(profile)
    }

    public func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        save()
        PEQAudioEngine.shared.apply(profile: activeProfile)
    }

    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        profiles[index].name = trimmed
        save()
        if activeProfileID == id {
            PEQAudioEngine.shared.apply(profile: profiles[index])
        }
    }

    public func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)

        if activeProfileID == id {
            if profiles.isEmpty {
                activeProfileID = nil
            } else {
                let nextIndex = min(index, profiles.count - 1)
                activeProfileID = profiles[nextIndex].id
            }
        }

        save()
        PEQAudioEngine.shared.apply(profile: activeProfile)
    }

    public func setPreamp(for id: UUID, db: Float) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let stepped = (EQProfile.clampPreamp(db) * 10.0).rounded() / 10.0
        profiles[index].preampDB = stepped
        save()
        if activeProfileID == id {
            PEQAudioEngine.shared.apply(profile: profiles[index])
        }
    }

    public func stepPreamp(for id: UUID, by delta: Float) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        setPreamp(for: id, db: profile.preampDB + delta)
    }

    public func toggleBand(profileID: UUID, bandID: UUID) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let bandIndex = profiles[profileIndex].bands.firstIndex(where: { $0.id == bandID }) else {
            return
        }
        profiles[profileIndex].bands[bandIndex].isEnabled.toggle()
        save()
        if activeProfileID == profileID {
            PEQAudioEngine.shared.apply(profile: profiles[profileIndex])
        }
    }

    // MARK: - Persistence

    @discardableResult
    private func appendAndActivate(_ profile: EQProfile) -> EQProfile {
        profiles.insert(profile, at: 0)
        activeProfileID = profile.id
        save()
        PEQAudioEngine.shared.apply(profile: profile)
        return profile
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            activeProfileID = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedStore.self, from: data)
            profiles = decoded.profiles
            if let savedID = decoded.activeProfileID,
               profiles.contains(where: { $0.id == savedID }) {
                activeProfileID = savedID
            } else {
                activeProfileID = profiles.first?.id
            }
        } catch {
            logger.error("Failed to load profiles: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            profiles = []
            activeProfileID = nil
        }
    }

    private func save() {
        do {
            let payload = PersistedStore(profiles: profiles, activeProfileID: activeProfileID)
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
