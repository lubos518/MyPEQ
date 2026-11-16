//  MyPEQApp.swift
//  Application entry point wiring PEQAudioEngine, ProfileStore, and incoming .txt file URLs.

import SwiftUI

@main
public struct MyPEQApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let audioEngine = PEQAudioEngine.shared
    private let profileStore = ProfileStore.shared

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    audioEngine.apply(profile: profileStore.combinedActiveProfile)
                    audioEngine.start()
                }
                .onOpenURL { url in
                    do {
                        try profileStore.importFromFileURL(url)
                    } catch {
                        profileStore.lastErrorMessage = error.localizedDescription
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        audioEngine.apply(profile: profileStore.combinedActiveProfile)
                        audioEngine.start()
                    }
                }
        }
    }
}
