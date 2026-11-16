//  PEQAudioEngine.swift
//  Bit-transparent Float32 audio engine hosting the ETLinkReceiver loopback socket,
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
    @Published public private(set) var receivedFrames: UInt64 = 0
    @Published public private(set) var lastErrorMessage: String?

    @Published public var isMasterEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isMasterEnabled, forKey: Self.masterEnabledDefaultsKey)
            applyCurrentParameters()
        }
    }

    public let advertisedServiceName: String

    private static let linkFixedSampleRate: Double = 48000.0
    private static let masterEnabledDefaultsKey = "cz.lubos.mypeq.masterEnabled"
    private let logger = Logger(subsystem: "cz.lubos.mypeq", category: "audio-engine")

    private var engine = AVAudioEngine()
    private var eqNode = AVAudioUnitEQ(numberOfBands: APOParser.maxHardwareBands)
    private var sourceNode: AVAudioSourceNode?
    private let renderContext = PCMRenderContext()
    private var activeProfile: EQProfile?

    private var isSpeakerOverrideActive = false
    private var routeEscapeAttempts = 0
    private var lastRouteEscapeTime: TimeInterval = 0
    private var lastStartAttempt: TimeInterval = 0
    private var isInterrupted = false
    private var lastObservedReceivedFrames: UInt64 = 0

    private var statusTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        self.advertisedServiceName = String(cString: MyPEQReceiverGetServiceName())
        if UserDefaults.standard.object(forKey: Self.masterEnabledDefaultsKey) != nil {
            self.isMasterEnabled = UserDefaults.standard.bool(forKey: Self.masterEnabledDefaultsKey)
        }
        // Keep 127.0.0.1:47101 open immediately so MediaDeviceExtension can connect at any time.
        self.isReceiverListening = MyPEQReceiverStart()
        installSessionObservers()
    }

    public func start() {
        if isEngineRunning && engine.isRunning {
            refreshStatusSnapshot()
            return
        }

        lastStartAttempt = ProcessInfo.processInfo.systemUptime
        lastErrorMessage = nil

        if !MyPEQReceiverIsRunning() {
            isReceiverListening = MyPEQReceiverStart()
        } else {
            isReceiverListening = true
        }

        configureAudioSession()

        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = sessionRate > 0 ? sessionRate : Self.linkFixedSampleRate
        MyPEQReceiverSetSampleRate(Self.linkFixedSampleRate)

        rebuildAndStartGraph()
        applyCurrentParameters()
        startStatusTimer()
        refreshRouteState()
        refreshStatusSnapshot()
    }

    public func stop(keepListening: Bool = false) {
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
        try? AVAudioSession.sharedInstance().setActive(false)

        if !keepListening {
            MyPEQReceiverStop()
            isReceiverListening = false
        }
        isEngineRunning = false
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
            // Matching EffectDeck's session configuration: .playAndRecord avoids
            // MediaExperience assigning LongFormAudio routing policy (which pulls the app
            // onto its own virtual route) while keeping A2DP Bluetooth headphones active
            // and allowing overrideOutputAudioPort(.speaker) as an escape hatch.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
            )
            try? session.setPreferredSampleRate(Self.linkFixedSampleRate)
            try session.setActive(true)
            pinInputToBuiltInMic(session)
        } catch {
            logger.error("AVAudioSession configuration failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Pinning input to the built-in mic prevents iOS from dropping Bluetooth A2DP stereo
    /// down into mono HFP call profile when .playAndRecord is active.
    private func pinInputToBuiltInMic(_ session: AVAudioSession, route: AVAudioSessionRouteDescription? = nil) {
        if let route, route.inputs.contains(where: { $0.portType == .builtInMic }) {
            return
        }
        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            return
        }
        try? session.setPreferredInput(builtInMic)
    }

    private func rebuildAndStartGraph() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        eqNode = AVAudioUnitEQ(numberOfBands: APOParser.maxHardwareBands)

        // ETLinkReceiver delivers 48 kHz 32-bit Float32 stereo frames from MyPEQExtension.
        // Keeping the DSP graph fixed at 48 kHz lets mainMixerNode->outputNode handle any
        // hardware rate seamlessly without tearing down the engine on route transitions.
        guard let linkFormat = AVAudioFormat(standardFormatWithSampleRate: Self.linkFixedSampleRate, channels: 2) else {
            lastErrorMessage = "Failed to initialize 48 kHz Float32 stereo format."
            return
        }

        let source = makeLoopbackSourceNode(format: linkFormat, context: renderContext)
        sourceNode = source

        engine.attach(source)
        engine.attach(eqNode)

        engine.connect(source, to: eqNode, format: linkFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: linkFormat)
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
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleEngineConfigurationChange()
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
                    self?.isInterrupted = false
                    self?.stop(keepListening: true)
                    self?.start()
                }
            }
        )
    }

    private func handleRouteChange() {
        refreshRouteState()

        if !engine.isRunning && !isInterrupted {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStartAttempt >= 1.0 {
                stop(keepListening: true)
                start()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        refreshRouteState()

        guard !engine.isRunning, !isInterrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastStartAttempt >= 1.0 {
            stop(keepListening: true)
            start()
        }
    }

    private func handleInterruption(typeValue: UInt?) {
        guard let raw = typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }

        switch type {
        case .began:
            isInterrupted = true
            isEngineRunning = false
        case .ended:
            isInterrupted = false
            configureAudioSession()
            if !engine.isRunning {
                rebuildAndStartGraph()
                applyCurrentParameters()
            }
        @unknown default:
            break
        }
    }

    private func refreshRouteState() {
        let session = AVAudioSession.sharedInstance()
        let cur = session.currentRoute
        pinInputToBuiltInMic(session, route: cur)

        let hardwareRate = session.sampleRate
        if hardwareRate > 0, abs(sampleRate - hardwareRate) > 1.0 {
            sampleRate = hardwareRate
        }

        let outputs = cur.outputs
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
        if !MyPEQReceiverIsRunning() {
            _ = MyPEQReceiverStart()
        }

        let listening = MyPEQReceiverIsRunning()
        if isReceiverListening != listening {
            isReceiverListening = listening
        }

        if !engine.isRunning && !isInterrupted {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStartAttempt >= 1.0 {
                stop(keepListening: true)
                start()
                return
            }
        }

        let running = engine.isRunning
        if isEngineRunning != running {
            isEngineRunning = running
        }

        let frames = MyPEQReceiverGetBufferedFrames()
        if bufferedFrames != frames {
            bufferedFrames = frames
        }

        let totalRecv = MyPEQReceiverGetReceivedFrames()
        let advancing = totalRecv > lastObservedReceivedFrames
        lastObservedReceivedFrames = totalRecv
        if receivedFrames != totalRecv {
            receivedFrames = totalRecv
        }

        let streaming = (MyPEQReceiverIsStreaming() || frames > 0 || advancing) && !isLoopbackDetected
        if isStreamingAudio != streaming {
            isStreamingAudio = streaming
        }
    }
}
