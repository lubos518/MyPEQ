//  PEQAudioEngine.swift
//  Bit-transparent Float32 audio engine hosting the local MyPEQ AirPlay receiver,
//  exact EqualizerAPO Q-to-bandwidth 20-band AVAudioUnitEQ, and A2DP/wired routing.

import AVFoundation
import Combine
import Foundation
import os

private final class PCMRenderContext: @unchecked Sendable {
    let maxFrames: Int
    let scratchInterleaved: UnsafeMutablePointer<Float>
    private let muteState = OSAllocatedUnfairLock(initialState: false)

    var isMuted: Bool {
        get { muteState.withLock { $0 } }
        set { muteState.withLock { $0 = newValue } }
    }

    init(maxFrames: Int = 8192) {
        self.maxFrames = maxFrames
        self.scratchInterleaved = .allocate(capacity: maxFrames * 2)
        self.scratchInterleaved.initialize(repeating: 0.0, count: maxFrames * 2)
    }

    deinit {
        scratchInterleaved.deinitialize(count: maxFrames * 2)
        scratchInterleaved.deallocate()
    }
}

private func makeLoopbackSourceNode(format: AVAudioFormat, context: PCMRenderContext) -> AVAudioSourceNode {
    return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let requestedFrames = Int(frameCount)
        let framesToRead = min(requestedFrames, context.maxFrames)
        let muted = context.isMuted

        if framesToRead > 0 {
            _ = MyPEQReceiverReadPCM(context.scratchInterleaved, UInt32(framesToRead))
        }

        if abl.count >= 2,
           let leftRaw = abl[0].mData,
           let rightRaw = abl[1].mData {
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)
            let interleaved = context.scratchInterleaved

            if muted {
                for i in 0..<requestedFrames {
                    left[i] = 0.0
                    right[i] = 0.0
                }
            } else {
                for i in 0..<framesToRead {
                    left[i] = interleaved[i &* 2]
                    right[i] = interleaved[i &* 2 &+ 1]
                }
                if framesToRead < requestedFrames {
                    for i in framesToRead..<requestedFrames {
                        left[i] = 0.0
                        right[i] = 0.0
                    }
                }
            }
            abl[0].mDataByteSize = UInt32(requestedFrames * MemoryLayout<Float>.size)
            abl[1].mDataByteSize = UInt32(requestedFrames * MemoryLayout<Float>.size)
        } else if abl.count == 1, let singleRaw = abl[0].mData {
            let dst = singleRaw.assumingMemoryBound(to: Float.self)
            let channels = max(Int(abl[0].mNumberChannels), 1)
            let interleaved = context.scratchInterleaved

            if muted {
                let totalSamples = requestedFrames * channels
                for i in 0..<totalSamples {
                    dst[i] = 0.0
                }
            } else if channels == 2 {
                dst.update(from: interleaved, count: framesToRead * 2)
                if framesToRead < requestedFrames {
                    let tailStart = framesToRead * 2
                    let tailCount = (requestedFrames - framesToRead) * 2
                    for i in 0..<tailCount {
                        dst[tailStart + i] = 0.0
                    }
                }
            } else {
                for i in 0..<framesToRead {
                    dst[i] = 0.5 * (interleaved[i &* 2] + interleaved[i &* 2 &+ 1])
                }
                if framesToRead < requestedFrames {
                    for i in framesToRead..<requestedFrames {
                        dst[i] = 0.0
                    }
                }
            }
            abl[0].mDataByteSize = UInt32(requestedFrames * channels * MemoryLayout<Float>.size)
        }

        return noErr
    }
}

@MainActor
public final class PEQAudioEngine: ObservableObject {
    public static let shared = PEQAudioEngine()

    @Published public private(set) var isEngineRunning: Bool = false
    @Published public private(set) var isReceiverListening: Bool = false
    @Published public private(set) var isStreamingAudio: Bool = false
    @Published public private(set) var sampleRate: Double = 48000.0
    @Published public private(set) var outputRouteName: String = "System Output"
    @Published public private(set) var isHeadphoneConnected: Bool = false
    @Published public private(set) var isLoopbackDetected: Bool = false
    @Published public private(set) var bufferedFrames: UInt32 = 0
    @Published public private(set) var lastErrorMessage: String?

    @Published public var isMasterEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isMasterEnabled, forKey: Self.masterEnabledDefaultsKey)
            applyCurrentParameters()
        }
    }

    public let advertisedServiceName: String

    private static let masterEnabledDefaultsKey = "com.mypeq.masterEnabled"
    private let logger = Logger(subsystem: "com.mypeq.app", category: "audio-engine")

    private var engine = AVAudioEngine()
    private var eqNode = AVAudioUnitEQ(numberOfBands: APOParser.maxHardwareBands)
    private var sourceNode: AVAudioSourceNode?
    private let renderContext = PCMRenderContext()
    private var activeProfile: EQProfile?

    private var isSpeakerOverrideActive = false
    private var routeEscapeAttempts = 0
    private var lastRouteEscapeTime: TimeInterval = 0

    private var statusTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        self.advertisedServiceName = String(cString: MyPEQReceiverGetServiceName())
        if UserDefaults.standard.object(forKey: Self.masterEnabledDefaultsKey) != nil {
            self.isMasterEnabled = UserDefaults.standard.bool(forKey: Self.masterEnabledDefaultsKey)
        }
        installSessionObservers()
    }

    public func start() {
        guard !isEngineRunning else {
            refreshStatusSnapshot()
            return
        }

        lastErrorMessage = nil
        configureAudioSession()

        let receiverStarted = MyPEQReceiverStart()
        isReceiverListening = receiverStarted

        let resolvedRate = resolveSampleRate()
        sampleRate = resolvedRate
        MyPEQReceiverSetSampleRate(resolvedRate)

        rebuildAndStartGraph(sampleRate: resolvedRate)
        applyCurrentParameters()
        startStatusTimer()
        refreshRouteState()
        refreshStatusSnapshot()
    }

    public func stop() {
        statusTimer?.invalidate()
        statusTimer = nil

        renderContext.isMuted = false
        if isSpeakerOverrideActive {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        }
        isSpeakerOverrideActive = false
        routeEscapeAttempts = 0
        lastRouteEscapeTime = 0

        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }

        MyPEQReceiverStop()
        isEngineRunning = false
        isReceiverListening = false
        isStreamingAudio = false
        bufferedFrames = 0
    }

    public func apply(profile: EQProfile?) {
        activeProfile = profile
        applyCurrentParameters()
    }

    public static func bandwidthInOctaves(fromQ qValue: Float) -> Float {
        APOParser.bandwidthInOctaves(fromQ: qValue)
    }

    // MARK: - Private Setup & Graph

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetoothA2DP, .mixWithOthers]
            )
            try? session.setPreferredSampleRate(MyPEQReceiverGetSampleRate())
            try session.setActive(true)
        } catch {
            logger.error("AVAudioSession configuration failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
        }
    }

    private func resolveSampleRate() -> Double {
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        if abs(sessionRate - 44100.0) < 5.0 {
            return 44100.0
        }
        if abs(sessionRate - 48000.0) < 5.0 {
            return 48000.0
        }
        let receiverRate = MyPEQReceiverGetSampleRate()
        return abs(receiverRate - 44100.0) < 5.0 ? 44100.0 : 48000.0
    }

    private func rebuildAndStartGraph(sampleRate: Double) {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        eqNode = AVAudioUnitEQ(numberOfBands: APOParser.maxHardwareBands)

        // 32-bit Float32 non-interleaved stereo preserves full dynamic range (including Dolby Atmos).
        // Zero compressor, limiter, AGC, or loudness normalization is inserted anywhere in this graph.
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            lastErrorMessage = "Failed to initialize Float32 stereo format at \(Int(sampleRate)) Hz."
            return
        }

        let source = makeLoopbackSourceNode(format: renderFormat, context: renderContext)
        sourceNode = source

        engine.attach(source)
        engine.attach(eqNode)

        engine.connect(source, to: eqNode, format: renderFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()

        do {
            try engine.start()
            isEngineRunning = engine.isRunning
        } catch {
            logger.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            isEngineRunning = false
        }
    }

    private func applyCurrentParameters() {
        let hardwareBands = eqNode.bands

        guard isMasterEnabled, let profile = activeProfile else {
            eqNode.globalGain = 0.0
            for bandParam in hardwareBands {
                bandParam.bypass = true
            }
            return
        }

        eqNode.globalGain = EQProfile.clampPreamp(profile.preampDB)

        let activeSlice = Array(profile.bands.prefix(hardwareBands.count))
        for (index, bandParam) in hardwareBands.enumerated() {
            guard index < activeSlice.count else {
                bandParam.gain = 0.0
                bandParam.bypass = true
                continue
            }

            let band = activeSlice[index]
            switch band.type {
            case .pk:
                bandParam.filterType = .parametric
            case .lsc, .ls:
                bandParam.filterType = .lowShelf
            case .hsc, .hs:
                bandParam.filterType = .highShelf
            }

            bandParam.frequency = EQBand.clampFrequency(band.frequency)
            // AVAudioUnitEQ supports gains up to +24 dB safely on iOS hardware/DSP nodes.
            bandParam.gain = min(max(band.gain, -30.0), 24.0)
            bandParam.bandwidth = APOParser.bandwidthInOctaves(fromQ: band.q)
            bandParam.bypass = !band.isEnabled
        }
    }

    // MARK: - Session & Route Observation

    private func installSessionObservers() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange()
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleInterruption(typeValue: typeValue)
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stop()
                    self?.start()
                }
            }
        )
    }

    private func handleRouteChange() {
        refreshRouteState()

        let currentRate = resolveSampleRate()
        if abs(currentRate - sampleRate) > 1.0, isEngineRunning {
            sampleRate = currentRate
            MyPEQReceiverSetSampleRate(currentRate)
            rebuildAndStartGraph(sampleRate: currentRate)
            applyCurrentParameters()
        } else if !engine.isRunning, isReceiverListening {
            configureAudioSession()
            rebuildAndStartGraph(sampleRate: sampleRate)
            applyCurrentParameters()
        }
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let raw = typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }

        switch type {
        case .began:
            isEngineRunning = false
        case .ended:
            configureAudioSession()
            if !engine.isRunning {
                rebuildAndStartGraph(sampleRate: sampleRate)
                applyCurrentParameters()
            }
        @unknown default:
            break
        }
    }

    private func refreshRouteState() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        guard let primary = outputs.first else {
            outputRouteName = "No Output"
            isHeadphoneConnected = false
            isLoopbackDetected = false
            renderContext.isMuted = false
            return
        }

        let nameStem = String(cString: MyPEQReceiverGetServiceName())
        let loopback = outputs.contains {
            $0.portName.localizedCaseInsensitiveContains(nameStem)
                || $0.portName.localizedCaseInsensitiveContains("EffectDeck")
        }
        let onSpeaker = outputs.contains {
            $0.portType == .builtInSpeaker
        }

        renderContext.isMuted = loopback

        let now = ProcessInfo.processInfo.systemUptime
        if loopback {
            if (!isSpeakerOverrideActive || (now - lastRouteEscapeTime >= 3.0)) && routeEscapeAttempts < 3 {
                isSpeakerOverrideActive = true
                lastRouteEscapeTime = now
                routeEscapeAttempts += 1
                try? session.overrideOutputAudioPort(.speaker)
            }
        } else if isSpeakerOverrideActive && !onSpeaker {
            isSpeakerOverrideActive = false
            lastRouteEscapeTime = now
            routeEscapeAttempts = 0
            try? session.overrideOutputAudioPort(.none)
        }

        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothLE,
            .usbAudio
        ]

        let headphones = outputs.contains { headphonePorts.contains($0.portType) }
        outputRouteName = primary.portName
        isHeadphoneConnected = headphones
        isLoopbackDetected = loopback

        if !loopback {
            ProfileStore.shared.handleOutputRouteChanged(
                routeName: primary.portName,
                isHeadphoneRoute: headphones
            )
        }
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusSnapshot()
            }
        }
    }

    private func refreshStatusSnapshot() {
        let running = engine.isRunning
        if isEngineRunning != running {
            isEngineRunning = running
        }

        let listening = MyPEQReceiverIsRunning()
        if isReceiverListening != listening {
            isReceiverListening = listening
        }

        let streaming = MyPEQReceiverIsStreaming() && !isLoopbackDetected
        if isStreamingAudio != streaming {
            isStreamingAudio = streaming
        }

        let frames = MyPEQReceiverGetBufferedFrames()
        if bufferedFrames != frames {
            bufferedFrames = frames
        }
    }
}
