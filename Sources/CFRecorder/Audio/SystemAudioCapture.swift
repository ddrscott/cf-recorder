import AVFoundation
import AudioToolbox
import CoreAudio
import os

enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case noFormat
    case micDenied
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let status): "\(what) failed (OSStatus \(status))"
        case .noFormat: "Couldn't read the system audio format."
        case .micDenied: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .setup(let message): message
        }
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CaptureError.osStatus(what, status) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Captures everything the Mac plays (the other side of the call) with a Core Audio
/// process tap. Needs macOS 14.4+ and NSAudioCaptureUsageDescription; no Screen
/// Recording permission involved.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rates: NominalRate?
    private let queue = DispatchQueue(label: "cf-recorder.system-audio", qos: .userInitiated)

    /// `onBuffer` runs on a private queue and the buffer points at Core Audio's memory,
    /// so it has to be consumed before the closure returns.
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObjects())
        description.uuid = UUID()
        description.name = "Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the system audio tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd), "Reading the tap format")
        guard var format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.noFormat }

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recorder Tap",
            // The prefix keeps it out of the input device list (AudioDevices).
            kAudioAggregateDeviceUIDKey: "CFRecorder-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice), "Creating the aggregate device")
        aggregateID = aggregateDevice

        let rates = NominalRate(device: aggregateID)
        self.rates = rates
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, inputTime, _, _ in
            // The tap claims its own rate (48 kHz), but the aggregate runs on the output
            // device's clock and delivers at that rate. A Bluetooth headset in hands-free
            // mode runs at 16 kHz, so labeling by the tap's format plays the guest back
            // 3x fast and the recognizer hears nothing it can use.
            let rate = rates.rate
            if format.sampleRate != rate {
                var adjusted = asbd
                adjusted.mSampleRate = rate
                guard let next = AVAudioFormat(streamDescription: &adjusted) else { return }
                Log.app.notice("System audio now at \(rate, privacy: .public) Hz")
                format = next
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            onBuffer(buffer, AVAudioTime(hostTime: inputTime.pointee.mHostTime))
        }, "Creating the audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "Starting system audio capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        rates = nil
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var translate = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &translate,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var outputAddress = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &device), "Finding the output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid), "Reading the output device ID")
        guard let uid else { throw CaptureError.osStatus("Reading the output device ID", -1) }
        return uid.takeRetainedValue() as String
    }
}

/// One input device. `nil` follows whatever macOS has as the default input. Each
/// instance runs its own engine, so two of them can record two devices at once.
/// A device's nominal sample rate, kept current by a property listener so the audio
/// callback can read it without calling into Core Audio.
private final class NominalRate: @unchecked Sendable {
    private let device: AudioObjectID
    private let value = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenAddress = address(kAudioDevicePropertyNominalSampleRate)

    var rate: Double { value.withLock { $0 } }

    init(device: AudioObjectID) {
        self.device = device
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(device, &listenAddress, nil, listener)
    }

    deinit {
        if let listener { AudioObjectRemovePropertyListenerBlock(device, &listenAddress, nil, listener) }
    }

    private func refresh() {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0 else { return }
        value.withLock { $0 = rate }
    }
}

/// Captures one input device with AVAudioEngine.
///
/// The engine stops itself whenever the device reconfigures, and it posts
/// `AVAudioEngineConfigurationChange` without restarting. A Bluetooth headset does this
/// the moment its mic opens: it switches from A2DP to the hands-free profile and changes
/// sample rate. Pinning a device does it too. So every config change rebuilds the tap
/// and starts the engine again; otherwise the mic delivers nothing for the whole call.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let device: AudioDevice?
    private let queue = DispatchQueue(label: "MicCapture")
    private var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(device: AudioDevice? = nil) {
        self.device = device
    }

    static func requestAccess() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.micDenied }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        self.onBuffer = onBuffer
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Changes come in bursts while the device settles; let them pile up first.
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.restart() }
        }
        try queue.sync { try run() }
    }

    func stop() {
        queue.sync {
            stopped = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func restart() {
        guard !stopped else { return }
        Log.app.notice("Mic config changed; restarting \(self.device?.name ?? "the default input")")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try run()
        } catch {
            Log.app.error("Mic restart failed: \(error.localizedDescription)")
        }
    }

    private func run() throws {
        let input = engine.inputNode
        if let device {
            // Has to happen before reading the format, which comes from the device.
            guard let unit = input.audioUnit else { throw CaptureError.osStatus("Opening \(device.name)", -1) }
            var id = device.id
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
                "Switching to \(device.name)"
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError.osStatus("Reading \(device?.name ?? "the default input")'s format", -1)
        }
        let onBuffer = self.onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            onBuffer?(buffer, time)
        }
        engine.prepare()
        try engine.start()
    }
}
