import Foundation
import AppKit
import CoreAudio

/// File-scope C callback for CoreAudio property changes. Routes back to the MediaController
/// instance via the opaque client data pointer we registered with.
private let audioPropertyListener: AudioObjectPropertyListenerProc = { (_, _, _, clientData) -> OSStatus in
    guard let data = clientData else { return noErr }
    let controller = Unmanaged<MediaController>.fromOpaque(data).takeUnretainedValue()
    DispatchQueue.main.async { controller.handleAudioPropertyChange() }
    return noErr
}

/// Pauses media, mutes audio, freezes browsers/media apps, and guards mute/volume
/// against the child using keyboard media keys while the lock screen is active.
class MediaController {
    private var wasMutedBeforeLock = false
    private var savedVolume: Float32?
    private var isLocked = false
    private var suspendedPIDs: Set<pid_t> = []
    private var listenerDeviceID: AudioDeviceID?
    private var listenersAttached = false
    private var appLaunchObserver: NSObjectProtocol?

    /// Bundle IDs of apps whose processes we SIGSTOP on lock. Frozen processes can't
    /// respond to media keys (F7/F8) or play audio/video.
    private let mediaBundleIDs: Set<String> = [
        // Browsers
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "company.thebrowser.Browser",        // Arc
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",                // Orion
        // Media players
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "com.spotify.client",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.plexapp.plexmediaplayer",
        "tv.plex.desktop",
        // Communication (often carry video/audio)
        "com.tdesktop.Telegram",
        "ru.keepcoder.Telegram",
        "us.zoom.xos",
        "com.hnc.Discord",
    ]

    // MARK: - MediaRemote (private framework, loaded dynamically)

    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

    private lazy var sendCommand: MRMediaRemoteSendCommandFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            NSLog("[UsageTimeAgent] MediaController: failed to load MediaRemote framework")
            return nil
        }
        guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
            NSLog("[UsageTimeAgent] MediaController: MRMediaRemoteSendCommand not found")
            return nil
        }
        return unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunc.self)
    }()

    private let kMRPause: UInt32 = 1

    // MARK: - CoreAudio helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func isMuted(device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return muted != 0
    }

    private func setMuted(_ mute: Bool, device: AudioDeviceID) {
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            NSLog("[UsageTimeAgent] MediaController: failed to set mute (\(status)), trying volume fallback")
            setVolumeFallback(mute: mute, device: device)
        }
    }

    /// Fallback: set volume to 0 if mute property is not supported (e.g. some USB DACs).
    private func setVolumeFallback(mute: Bool, device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float32>.size)

        if mute {
            var currentVolume: Float32 = 0
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &currentVolume)
            savedVolume = currentVolume
            var zero: Float32 = 0
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &zero)
        } else if let vol = savedVolume {
            var restored = vol
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &restored)
            savedVolume = nil
        }
    }

    private func currentVolume(device: AudioDeviceID) -> Float32 {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &vol)
        return vol
    }

    private func setVolume(_ value: Float32, device: AudioDeviceID) {
        var v = value
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &v)
    }

    // MARK: - Audio property listeners (re-mute when child uses media keys)

    private func attachAudioListeners(device: AudioDeviceID) {
        guard !listenersAttached else { return }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(device, &muteAddr, audioPropertyListener, selfPtr)
        AudioObjectAddPropertyListener(device, &volAddr, audioPropertyListener, selfPtr)
        listenersAttached = true
    }

    private func detachAudioListeners(device: AudioDeviceID) {
        guard listenersAttached else { return }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(device, &muteAddr, audioPropertyListener, selfPtr)
        AudioObjectRemovePropertyListener(device, &volAddr, audioPropertyListener, selfPtr)
        listenersAttached = false
    }

    /// Called from the CoreAudio callback (already hopped to main). Re-applies mute
    /// if the child toggled it off or raised volume via media keys while locked.
    fileprivate func handleAudioPropertyChange() {
        guard isLocked, let device = listenerDeviceID else { return }
        if !isMuted(device: device) {
            setMuted(true, device: device)
            NSLog("[UsageTimeAgent] MediaController: re-muted (media key bypass blocked)")
        }
    }

    // MARK: - Process suspension

    private func suspendMediaApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, mediaBundleIDs.contains(bid) else { continue }
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            if kill(pid, SIGSTOP) == 0 {
                suspendedPIDs.insert(pid)
                NSLog("[UsageTimeAgent] MediaController: SIGSTOP \(bid) (pid \(pid))")
            } else {
                NSLog("[UsageTimeAgent] MediaController: SIGSTOP failed for \(bid) (pid \(pid)), errno \(errno)")
            }
        }
    }

    private func resumeMediaApps() {
        for pid in suspendedPIDs {
            kill(pid, SIGCONT)
        }
        if !suspendedPIDs.isEmpty {
            NSLog("[UsageTimeAgent] MediaController: SIGCONT'd \(suspendedPIDs.count) processes")
        }
        suspendedPIDs.removeAll()
    }

    /// Watch for apps launched while locked (child opens a new browser) and freeze them immediately.
    private func startAppLaunchObserver() {
        guard appLaunchObserver == nil else { return }
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, self.isLocked else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard let bid = app.bundleIdentifier, self.mediaBundleIDs.contains(bid) else { return }
            let pid = app.processIdentifier
            guard pid > 0 else { return }
            if kill(pid, SIGSTOP) == 0 {
                self.suspendedPIDs.insert(pid)
                NSLog("[UsageTimeAgent] MediaController: SIGSTOP newly launched \(bid) (pid \(pid))")
            }
        }
    }

    private func stopAppLaunchObserver() {
        if let token = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appLaunchObserver = nil
        }
    }

    // MARK: - Public API

    init() {
        // Crash recovery: if a previous agent instance was killed while holding
        // media apps in SIGSTOP, they're still frozen and the user can't recover.
        // SIGCONT is a no-op for running processes, so this is safe to always run.
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, mediaBundleIDs.contains(bid) else { continue }
            let pid = app.processIdentifier
            if pid > 0 { kill(pid, SIGCONT) }
        }
    }

    /// Called when lock screen appears.
    func onLock() {
        guard !isLocked else { return }
        isLocked = true

        // 1. MediaRemote pause (covers native media apps that honor Now Playing)
        if let send = sendCommand {
            _ = send(kMRPause, nil)
        }

        // 2. Mute audio + attach listeners so F10/mute key toggles re-apply instantly
        if let device = getDefaultOutputDevice() {
            listenerDeviceID = device
            wasMutedBeforeLock = isMuted(device: device)
            if !wasMutedBeforeLock {
                setMuted(true, device: device)
            }
            attachAudioListeners(device: device)
        }

        // 3. Freeze browsers/media apps — their play/pause keys tap into empty space
        suspendMediaApps()

        // 4. Catch new launches during lock
        startAppLaunchObserver()

        NSLog("[UsageTimeAgent] MediaController: locked (suspended \(suspendedPIDs.count) apps)")
    }

    /// Called when lock screen is dismissed.
    func onUnlock() {
        guard isLocked else { return }
        isLocked = false

        stopAppLaunchObserver()
        resumeMediaApps()

        if let device = listenerDeviceID {
            detachAudioListeners(device: device)
            if !wasMutedBeforeLock {
                setMuted(false, device: device)
            }
            if let vol = savedVolume {
                setVolume(vol, device: device)
                savedVolume = nil
            }
        }
        wasMutedBeforeLock = false
        listenerDeviceID = nil

        NSLog("[UsageTimeAgent] MediaController: unlocked")
    }

    deinit {
        stopAppLaunchObserver()
        if let device = listenerDeviceID {
            detachAudioListeners(device: device)
        }
        // Best-effort: wake up anything still frozen if the agent is torn down mid-lock.
        resumeMediaApps()
    }
}
