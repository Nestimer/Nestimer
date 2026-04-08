import Foundation
import CoreAudio

/// Pauses system media playback and mutes/unmutes audio when the lock screen is shown/hidden.
class MediaController {
    private var wasMutedBeforeLock = false
    private var savedVolume: Float32?

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

    // MediaRemote command constants
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
        var size = UInt32(MemoryLayout<UInt32>.size)
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
            // Save current volume before zeroing
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

    // MARK: - Public API

    /// Pause media and mute audio. Called when lock screen appears.
    func onLock() {
        // 1. Pause media playback
        if let send = sendCommand {
            let result = send(kMRPause, nil)
            NSLog("[UsageTimeAgent] MediaController: sent pause command (success: \(result))")
        }

        // 2. Mute system audio (remember previous state)
        if let device = getDefaultOutputDevice() {
            wasMutedBeforeLock = isMuted(device: device)
            if !wasMutedBeforeLock {
                setMuted(true, device: device)
                NSLog("[UsageTimeAgent] MediaController: muted audio")
            }
        }
    }

    /// Unmute audio (restore pre-lock state). Called when lock screen is dismissed.
    func onUnlock() {
        if let device = getDefaultOutputDevice() {
            if !wasMutedBeforeLock {
                setMuted(false, device: device)
                NSLog("[UsageTimeAgent] MediaController: unmuted audio")
            }
            // Restore volume if we used the volume fallback
            if let vol = savedVolume {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<Float32>.size)
                var restored = vol
                AudioObjectSetPropertyData(device, &address, 0, nil, size, &restored)
                savedVolume = nil
                NSLog("[UsageTimeAgent] MediaController: restored volume to \(vol)")
            }
        }
        wasMutedBeforeLock = false
    }
}
