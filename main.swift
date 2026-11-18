// mic-guard: stop macOS using Bluetooth headphones as the microphone.
//
// Bluetooth headphones can't play high-quality stereo and use their mic at the
// same time. As soon as macOS makes them the input device, they drop to the
// hands-free profile and everything sounds muffled and mono. mic-guard watches
// the default input and, when it becomes a Bluetooth device, switches it back
// to the input you were using before (or the built-in mic).
//
//   mic-guard            run the watcher (the LaunchAgent does this)
//   mic-guard pause      allow Bluetooth mics, e.g. for a call
//   mic-guard resume     block them again and fix the input now
//   mic-guard status     show the current input and whether the guard is on

import CoreAudio
import Foundation

let label = "local.mic-guard"
let pauseFlag = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".mic-guard-paused").path
let resumeNotification = Notification.Name("\(label).resume")

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(message)")
    fflush(stdout)
}

// MARK: - Core Audio helpers

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultInput() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

func setDefaultInput(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectSetPropertyData(system, &addr, 0, nil, size, &device) == noErr
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func transport(_ id: AudioDeviceID) -> UInt32 {
    var addr = address(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return value
}

func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
          let cf = value?.takeRetainedValue() else { return nil }
    return cf as String
}

func name(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioObjectPropertyName) ?? "device \(id)" }

/// Stable across reconnects, unlike the AudioDeviceID.
func uid(_ id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

func hasInput(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transport(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

func isVirtual(_ id: AudioDeviceID) -> Bool {
    let t = transport(id)
    return t == kAudioDeviceTransportTypeVirtual || t == kAudioDeviceTransportTypeAggregate
        || t == kAudioDeviceTransportTypeAutoAggregate
}

// MARK: - Guard

var isPaused: Bool { FileManager.default.fileExists(atPath: pauseFlag) }

/// The last non-Bluetooth input in use, so the guard can go back to it.
var lastGoodInputUID: String?

/// Where to move the input: the last non-Bluetooth input if it's still connected,
/// otherwise the built-in mic, then a USB mic, then any other real (non-virtual) mic.
func fallbackInput() -> AudioDeviceID? {
    let mics = allDevices().filter { hasInput($0) && !isBluetooth($0) }
    if let saved = lastGoodInputUID, let match = mics.first(where: { uid($0) == saved }) {
        return match
    }
    return mics.first { transport($0) == kAudioDeviceTransportTypeBuiltIn }
        ?? mics.first { transport($0) == kAudioDeviceTransportTypeUSB }
        ?? mics.first { !isVirtual($0) }
}

/// If the default input is a Bluetooth device, move it somewhere better.
func enforce(_ reason: String) {
    guard let current = defaultInput() else { return }
    guard isBluetooth(current) else {
        lastGoodInputUID = uid(current)
        return
    }
    guard !isPaused else { return }
    guard let target = fallbackInput() else {
        log("Input is \(name(current)) but there is no other microphone to switch to")
        return
    }
    if setDefaultInput(target) {
        log("Input was \(name(current)), switched back to \(name(target)) [\(reason)]")
    } else {
        log("Could not switch input from \(name(current)) to \(name(target))")
    }
}

// MARK: - Output quality
//
// Even after nothing is using the Bluetooth mic any more, macOS sometimes leaves
// the headphones stuck in headset mode: the output device runs at 16 or 24 kHz
// instead of 44.1/48 kHz. Asking for the highest rate the output offers puts
// them back into high-quality mode.

func intProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return value
}

func sampleRate(_ id: AudioDeviceID) -> Double {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
    return rate
}

func availableRates(_ id: AudioDeviceID) -> [Double] {
    var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
    var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                   count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
    return ranges.map { $0.mMaximum }
}

func hasOutput(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
}

/// Bluetooth headphones show up as a separate output-only device (plus an input-only one).
func bluetoothOutputs() -> [AudioDeviceID] {
    allDevices().filter { isBluetooth($0) && hasOutput($0) && !hasInput($0) }
}

func bluetoothMicInUse() -> Bool {
    allDevices().contains {
        isBluetooth($0) && hasInput($0) && intProperty($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }
}

/// If Bluetooth headphones are stuck in headset mode and nothing is using their mic,
/// put them back into high-quality mode.
func restoreQuality(_ reason: String) {
    guard !isPaused, !bluetoothMicInUse() else { return }
    for output in bluetoothOutputs() {
        let current = sampleRate(output)
        guard let best = availableRates(output).max(), best >= 44_100, current < best else { continue }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = best
        let status = AudioObjectSetPropertyData(output, &addr, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &rate)
        if status == noErr {
            log("\(name(output)) was stuck in headset mode (\(Int(current)) Hz), restored to \(Int(best)) Hz [\(reason)]")
        } else {
            log("Could not restore \(name(output)) to \(Int(best)) Hz (error \(status))")
        }
    }
}

// MARK: - Watcher

var watchedDevices = Set<AudioDeviceID>()

/// Notice when an app stops using a Bluetooth mic, or the headphones drop into
/// headset mode for any other reason, so they can be restored.
func watchBluetoothDevices() {
    let present = Set(allDevices())
    watchedDevices.formIntersection(present)
    for device in present where isBluetooth(device) && !watchedDevices.contains(device) {
        watchedDevices.insert(device)
        let isMic = hasInput(device)
        var addr = address(isMic ? kAudioDevicePropertyDeviceIsRunningSomewhere
                                 : kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(device, &addr, .main) { _, _ in
            // Wait a moment: when a call starts, the rate drops just before the mic is in use.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                restoreQuality(isMic ? "Bluetooth mic released" : "headphones changed mode")
            }
        }
    }
}

func check(_ reason: String) {
    enforce(reason)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { restoreQuality(reason) }
}

func watch() -> Never {
    let queue = DispatchQueue.main
    var inputAddr = address(kAudioHardwarePropertyDefaultInputDevice)
    AudioObjectAddPropertyListenerBlock(system, &inputAddr, queue) { _, _ in
        check("default input changed")
    }
    // macOS can pick the headphones as input a moment after they connect,
    // so check again shortly after the device list changes.
    var devicesAddr = address(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(system, &devicesAddr, queue) { _, _ in
        watchBluetoothDevices()
        check("device connected")
        queue.asyncAfter(deadline: .now() + 1.5) { check("device connected, recheck") }
    }
    // `mic-guard resume` asks the running watcher to fix things straight away.
    DistributedNotificationCenter.default().addObserver(
        forName: resumeNotification, object: nil, queue: .main
    ) { _ in
        check("resumed")
    }
    log("mic-guard running\(isPaused ? " (paused)" : "")")
    watchBluetoothDevices()
    check("startup")
    RunLoop.main.run()
    exit(0)
}

func watcherIsRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(getuid())/\(label)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func describe(_ id: AudioDeviceID) -> String {
    let kind: String
    switch transport(id) {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        kind = isPaused ? "Bluetooth, allowed while paused" : "Bluetooth, will be switched"
    case kAudioDeviceTransportTypeUSB: kind = "USB"
    case kAudioDeviceTransportTypeBuiltIn: kind = "built-in"
    default: kind = "other"
    }
    return "\(name(id)) (\(kind))"
}

// MARK: - Command line

switch CommandLine.arguments.dropFirst().first {
case nil, "run":
    watch()
case "pause":
    FileManager.default.createFile(atPath: pauseFlag, contents: nil)
    print("Paused. Bluetooth mics can be used now. Run `mic-guard resume` when you're done.")
case "resume":
    try? FileManager.default.removeItem(atPath: pauseFlag)
    DistributedNotificationCenter.default().postNotificationName(
        resumeNotification, object: nil, userInfo: nil, deliverImmediately: true)
    usleep(2_500_000)
    print("Guarding again. Input: \(defaultInput().map(describe) ?? "none")")
case "status":
    print("Watcher: \(watcherIsRunning() ? "running" : "NOT running (run ./install.sh)")")
    print("Guard:   \(isPaused ? "PAUSED (Bluetooth mics allowed)" : "on (Bluetooth mics are blocked)")")
    print("Input:   \(defaultInput().map(describe) ?? "none")")
    for output in bluetoothOutputs() {
        let rate = Int(sampleRate(output))
        print("Output:  \(name(output)) (\(rate) Hz, \(rate >= 44_100 ? "high quality" : "headset mode"))")
    }
case "-h", "--help", "help":
    print("usage: mic-guard [run | pause | resume | status]")
default:
    print("usage: mic-guard [run | pause | resume | status]")
    exit(1)
}
