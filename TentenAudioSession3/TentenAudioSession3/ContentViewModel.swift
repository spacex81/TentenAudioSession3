import Foundation
import AVFoundation
import SwiftUI
import LiveKit
import WebRTC

class ContentViewModel:  ObservableObject, RoomDelegate {
    static let shared = ContentViewModel()
    
    var room: Room?

    let livekitUrl = "wss://tentwenty-bp8gb2jg.livekit.cloud"
    let handleLiveKitTokenUrl = "https://us-central1-tentenv2-36556.cloudfunctions.net/handleLivekitToken"
    
    @Published var isConnected: Bool = false
    @Published var isPublished: Bool = false
    
    var liveKitTaskId: UIBackgroundTaskIdentifier = .invalid
    var audioTaskId: UIBackgroundTaskIdentifier = .invalid
    
    // Silent Audio
    var audioPlayer: AVAudioPlayer?
    var isBackgroundTaskRunning = false

    init() {
        AudioManager.shared.customConfigureAudioSessionFunc = customConfig

        let roomOptions = RoomOptions(adaptiveStream: true, dynacast: true)
        room = Room(delegate: self, roomOptions: roomOptions)
        
        setupAudioRouteChangeNotification()
    }
    
    func handleScenePhaseChange(to newScenePhase: ScenePhase) {
        switch newScenePhase {
        case .active:
            NSLog("LOG: App is active and in the foreground")
            Task {
                await disconnect()
            }
        case .inactive:
            NSLog("LOG: App is inactive")
        case .background:
            NSLog("LOG: App is in the background")
            // silent audio background task
            startLiveKitTask()
        @unknown default:
            break
        }
    }
    
    
    func customConfig(newState: AudioManager.State, oldState: AudioManager.State) {
        DispatchQueue.liveKit.async { [weak self] in
            guard let self else { return }

            NSLog("LOG: Logging for customConfig")
            NSLog("LOG: old audio track: \(oldState.trackState)")
            NSLog("LOG: new audio track: \(newState.trackState)")

            let configuration = RTCAudioSessionConfiguration.webRTC()
            var setActive: Bool?

            if newState.trackState == .remoteOnly {
                NSLog("LOG: only remote is speaking")
//                configuration.category = AVAudioSession.Category.playback.rawValue
//                configuration.mode = AVAudioSession.Mode.default.rawValue
//                configuration.categoryOptions = [.mixWithOthers]
                
//                configuration.category = AVAudioSession.Category.playAndRecord.rawValue
//                configuration.mode = AVAudioSession.Mode.videoChat.rawValue
//                configuration.categoryOptions = [.mixWithOthers]
                
            } else if [.localOnly, .localAndRemote].contains(newState.trackState) {
                NSLog("LOG: local is speaking")
                configuration.category = AVAudioSession.Category.playAndRecord.rawValue
                configuration.mode = AVAudioSession.Mode.videoChat.rawValue
                configuration.categoryOptions = [
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                    .allowAirPlay,
                ]
            } else {
                NSLog("LOG: none are speaking")
                // If you add code here, publish local track will not work
            }

            if newState.trackState != .none, oldState.trackState == .none {
                setActive = true
            } else if newState.trackState == .none, oldState.trackState != .none {
                setActive = false
            }

            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }

            let maxAttempts = 3

            func attemptConfiguration(attempt: Int) {
                do {
                    let options = configuration.categoryOptions
                    var optionsArray: [String] = []
                    
                    if options.contains(.mixWithOthers) {
                        optionsArray.append("mixWithOthers")
                    }
                    if options.contains(.duckOthers) {
                        optionsArray.append("duckOthers")
                    }
                    if options.contains(.allowBluetooth) {
                        optionsArray.append("allowBluetooth")
                    }
                    if options.contains(.defaultToSpeaker) {
                        optionsArray.append("defaultToSpeaker")
                    }
                    if options.contains(.interruptSpokenAudioAndMixWithOthers) {
                        optionsArray.append("interruptSpokenAudioAndMixWithOthers")
                    }
                    if options.contains(.allowBluetoothA2DP) {
                        optionsArray.append("allowBluetoothA2DP")
                    }
                    if options.contains(.allowAirPlay) {
                        optionsArray.append("allowAirPlay")
                    }
                    
                    let optionsString = optionsArray.joined(separator: ", ")

                    NSLog("LOG: Attempt \(attempt) - configuring audio session category: \(configuration.category), mode: \(configuration.mode), options: [\(optionsString)], setActive: \(String(describing: setActive))")

                    if let setActive {
                        try session.setConfiguration(configuration, active: setActive)
                        NSLog("LOG: Succeed to \(setActive ? "activate" : "deactivate") audio session")
                    } else {
                        try session.setConfiguration(configuration)
                        NSLog("LOG: Succeed to configure audio session")
                    }
                } catch {
                    NSLog("LOG: Failed to configure audio session on attempt \(attempt) with error: \(error.localizedDescription)")
                    if attempt < maxAttempts {
                        NSLog("LOG: Retrying immediately...")
                        attemptConfiguration(attempt: attempt + 1)
                    } else {
                        NSLog("LOG: All attempts to configure audio session failed.")
                    }
                }
            }

            attemptConfiguration(attempt: 1)
        }
    }

    
    private func setupAudioRouteChangeNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    // most of the audio session configuration is done when route change
    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        NSLog("LOG: handleAudioRouteChange start")
        printReasonDescription(for: reason)
        logAudioSession()

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange:
            NSLog("LOG: Route change by category change")
            // Don't know why but LiveKit keep setting the audio session mode to 'voiceChat'
            // So we need to change it to 'videoChat' when 'category change' happens
            let audioSession = AVAudioSession.sharedInstance()
            if UIApplication.shared.applicationState == .background {
                do {
//                    try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
//                    try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [])
                    try audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [])
                } catch {
                    NSLog("LOG: Failed to change audio session category when the app is in the background, route change - category change")
                }
                NSLog("LOG: Successfully changed audio session into background mode")
            } else if audioSession.mode == .voiceChat {
                do {
                    try audioSession.setMode(.videoChat)
                } catch {
                    NSLog("LOG: Failed to change audio session mode from voice chat to video chat: \(error.localizedDescription)")
                }
                NSLog("LOG: Successfully changed audio session from .voiceChat to .videoChat")
            } else {
                NSLog("Log: Unhandled cases in route change - category change")
            }
            
        case .routeConfigurationChange:
            NSLog("LOG: Route change by configuration change")
        default:
            break
        }
    }

}



// MARK: LiveKit manager
extension ContentViewModel {
    func connect() async {
        NSLog("LOG: Connecting to LiveKit")
        guard let room  = self.room else {
            print("Room is not set")
            return
        }
        
        let token = await fetchLivekitToken()
        guard let livekitToken = token else {
            print("Failed to fetch livekit access token")
            return
        }
        
        do {
            try await room.connect(url: livekitUrl, token: livekitToken)
            DispatchQueue.main.async {
                self.isConnected = true
            }
            NSLog("LOG: LiveKit Connected")
        } catch {
            print("Failed to connect to LiveKit Room")
        }
        
    }
    
    func disconnect() async {
        NSLog("LOG: Disconnecting from LiveKit")
        guard let room  = self.room else {
            print("Room is not set")
            return
        }

        if isPublished {
            await unpublishAudio()
        }
        await room.disconnect()
        
        DispatchQueue.main.async {
            self.isConnected = false
        }
        
        NSLog("LOG: LiveKit disconnected")
        
//        playSilentAudio() //
    }
    
    func publishAudio() async {
        NSLog("LOG: Start enabling microphone for LiveKit audio track")
        guard let room = self.room else {
            NSLog("Room is not set")
            return
        }

        do {
            try await room.localParticipant.setMicrophone(enabled: true)
            DispatchQueue.main.async {
                self.isPublished = true
            }
            NSLog("LOG: Microphone enabled and LiveKit Audio track Published")
        } catch {
            NSLog("Failed to enable microphone for LiveKit Room: \(error)")
        }
    }
    
    func unpublishAudio() async {
        guard let room = self.room else {
            NSLog("Room is not set")
            return
        }

        do {
            // Disable the microphone
            try await room.localParticipant.setMicrophone(enabled: false)
            DispatchQueue.main.async {
                self.isPublished = false
            }
            NSLog("LOG: Microphone disabled and LiveKit Audio track unpublished")
        } catch {
            NSLog("Failed to disable microphone and unpublish audio track: \(error)")
        }
    }


    func fetchLivekitToken() async -> String? {
        guard let url = URL(string: handleLiveKitTokenUrl) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            return json?["livekitToken"] as? String
        } catch {
            NSLog("Failed to fetch token: \(error)")
            return nil
        }
    }

}

// MARK: Background task manager
extension ContentViewModel {
    
    func startLiveKitTask() {
        liveKitTaskId = UIApplication.shared.beginBackgroundTask(withName: "LiveKitTask") {
            self.endLiveKitTask()
        }

        guard liveKitTaskId != .invalid else {
            print("Failed to start LiveKit background task!")
            return
        }

        DispatchQueue.global(qos: .background).async {
            self.handleLiveKitTask()
        }
    }
    
    private func endLiveKitTask() {
        NSLog("LOG: LiveKit background task ended")
        if liveKitTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(liveKitTaskId)
            liveKitTaskId = .invalid
        }
    }

    private func handleLiveKitTask() {
        Task {
            await connect()
        }
    }
    
    func startAudioTask() {
        NSLog("LOG: Starting background audio task")
        endAudioTask()
        
        audioTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudioTask") {
            self.endAudioTask()
        }
        
        guard audioTaskId != .invalid else {
            NSLog("LOG: Failed to start audio background task")
            return
        }
        
        isBackgroundTaskRunning = true
        DispatchQueue.global(qos: .background).async {
            self.handleAudioTask()
        }
    }
    
    func endAudioTask() {
        isBackgroundTaskRunning = false
        NSLog("LOG: Ending background audio task")
        if audioTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(audioTaskId)
            audioTaskId = .invalid
        }
    }
    
    func stopAudioTask() {
        stopSilentAudio()
        endAudioTask()
    }
    
    func handleAudioTask() {
        playSilentAudio()
        
        for i in 1...30 {
            if !isBackgroundTaskRunning {
                break
            }
            if let player = audioPlayer, player.isPlaying {
                NSLog("LOG: Playing silent audio(\(i))...")
            }
            sleep(1)
        }

        stopSilentAudio()
        if isBackgroundTaskRunning {
            startAudioTask()
        }
    }
    
    func cleanUpBackgroundTasks() {
        // Stop any running background audio tasks
        stopAudioTask()
        
        // Disconnect from LiveKit and end the LiveKit background task
        Task {
            await disconnect()
            endLiveKitTask()
        }
        
        NSLog("LOG: Cleaned up background tasks")
    }
}

// MARK: Silent audio manager
extension ContentViewModel {
    
    func setupAudioPlayer() {
        NSLog("LOG: Setting up audio player for silent audio")
        guard let audioPath = Bundle.main.path(forResource: "test", ofType: "wav") else {
            NSLog("Failed to find the audio file")
            return
        }
        let audioUrl = URL(fileURLWithPath: audioPath)
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
            audioPlayer?.numberOfLoops = -1 // Loop indefinitely
        } catch {
            NSLog("Failed to initialize audio player: %{public}@")
        }
    }

    func playSilentAudio() {
        if let player = audioPlayer, player.prepareToPlay() {
            NSLog("LOG: Start playing silent audio")
            player.play()
        } else {
            NSLog("LOG: Failed to prepare audio player for playing")
        }
    }
    
    func stopSilentAudio() {
        NSLog("LOG: Stop playing silent audio")
        audioPlayer?.stop()
    }
}

extension ContentViewModel {
    func logAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        NSLog("LOG: audio session category: \(audioSession.category.rawValue), mode: \(audioSession.mode.rawValue), options: \(audioSessionCategoryOptionsToString(audioSession.categoryOptions))")
    }
    
    func audioSessionCategoryOptionsToString(_ options: AVAudioSession.CategoryOptions) -> String {
        var optionsString = [String]()
        
        if options.contains(.mixWithOthers) {
            optionsString.append("Mix With Others")
        }
        if options.contains(.duckOthers) {
            optionsString.append("Duck Others")
        }
        if options.contains(.allowBluetooth) {
            optionsString.append("Allow Bluetooth")
        }
        if options.contains(.defaultToSpeaker) {
            optionsString.append("Default To Speaker")
        }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) {
            optionsString.append("Interrupt Spoken Audio And Mix With Others")
        }
        if options.contains(.allowBluetoothA2DP) {
            optionsString.append("Allow Bluetooth A2DP")
        }
        if options.contains(.allowAirPlay) {
            optionsString.append("Allow AirPlay")
        }
        
        return optionsString.joined(separator: ", ")
    }
    
    private func printReasonDescription(for reason: AVAudioSession.RouteChangeReason) {
        let reasonDescription: String
        switch reason {
        case .newDeviceAvailable:
            reasonDescription = "New device available"
        case .oldDeviceUnavailable:
            reasonDescription = "Old device unavailable"
        case .categoryChange:
            reasonDescription = "Category change"
        case .override:
            reasonDescription = "Override"
        case .wakeFromSleep:
            reasonDescription = "Wake from sleep"
        case .noSuitableRouteForCategory:
            reasonDescription = "No suitable route for category"
        case .routeConfigurationChange:
            reasonDescription = "Route configuration change"
        case .unknown:
            reasonDescription = "Unknown reason"
        @unknown default:
            reasonDescription = "Unknown reason"
        }
        
        NSLog("LOG: Audio route change reason description: \(reasonDescription)")
    }


}

extension DispatchQueue {
    static let liveKit = DispatchQueue(label: "tech.komaki.liveKit")
}
