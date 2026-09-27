import CoreAudio

/// Read-only Core Audio device queries.
enum HAL {
    static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }
}
