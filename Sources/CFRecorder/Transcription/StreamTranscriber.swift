import AVFoundation
import CoreMedia
import Speech
import os

/// One audio stream end to end: it saves the raw audio to disk, converts it for the
/// recognizer, and reports volatile and final text as it comes back.
final class StreamTranscriber: @unchecked Sendable {
    struct Update: Sendable {
        let speaker: Speaker
        let text: String
        let start: Double
        let end: Double
        let isFinal: Bool
    }

    let speaker: Speaker
    private let sessionStartHost: UInt64
    private let fileURL: URL
    private let onUpdate: @Sendable (Update) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // Touched only from the audio callback.
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileConverter: AVAudioConverter?
    private var fileFailed = false
    private var lastLevelHost: UInt64 = 0

    /// Seconds between the session start and this stream's first buffer. The recognizer's
    /// clock starts at the first buffer, so results get shifted by this onto the shared timeline.
    private let offset = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(
        speaker: Speaker,
        sessionStartHost: UInt64,
        fileURL: URL,
        onUpdate: @escaping @Sendable (Update) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.speaker = speaker
        self.sessionStartHost = sessionStartHost
        self.fileURL = fileURL
        self.onUpdate = onUpdate
        self.onLevel = onLevel
    }

    /// Whether any audio has arrived yet.
    var hasAudio: Bool { offset.withLock { $0 != nil } }

    func prepare(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.input = continuation

        let speaker = speaker
        let onUpdate = onUpdate
        let offset = offset
        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let shift = offset.withLock { $0 } ?? 0
                    onUpdate(Update(
                        speaker: speaker,
                        text: text,
                        start: result.range.start.seconds + shift,
                        end: CMTimeRangeGetEnd(result.range).seconds + shift,
                        isFinal: result.isFinal
                    ))
                }
            } catch {
                Log.app.error("\(speaker.rawValue) transcription stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Called synchronously from the capture callback; the buffer may not outlive this call.
    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }

        offset.withLock { value in
            if value == nil {
                let now = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                value = now > sessionStartHost
                    ? AVAudioTime.seconds(forHostTime: now - sessionStartHost)
                    : 0
            }
        }

        write(buffer)
        reportLevel(buffer)

        guard let analyzerFormat, let input else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.app.error("\(self.speaker.rawValue) conversion failed: \(error.localizedDescription)")
            return
        }
        if converted.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async {
        input?.finish()
        input = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.app.error("\(self.speaker.rawValue) finalize failed: \(error.localizedDescription)")
        }
        await resultsTask?.value
        file?.close()
        file = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        if file == nil && !fileFailed {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                // No bit rate: a fixed one fails at a headset's 16 kHz (64 kbps does) and
                // the file never opens. The encoder's default fits every rate.
            ]
            do {
                file = try AVAudioFile(
                    forWriting: fileURL, settings: settings,
                    commonFormat: format.commonFormat, interleaved: format.isInterleaved
                )
            } catch {
                // Once is enough; retrying on every buffer just floods the log.
                fileFailed = true
                Log.app.error("Couldn't open \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let file else { return }
        do {
            // A Bluetooth headset can change sample rate mid-call; the file keeps its first format.
            if buffer.format == file.processingFormat {
                try file.write(from: buffer)
            } else if let converted = convertForFile(buffer, to: file.processingFormat) {
                try file.write(from: converted)
            }
        } catch {
            Log.app.error("Write to \(self.fileURL.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    private func convertForFile(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if fileConverter == nil || fileConverter?.inputFormat != buffer.format {
            fileConverter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let fileConverter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        fileConverter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = mach_absolute_time()
        guard AVAudioTime.seconds(forHostTime: now - lastLevelHost) > 0.08 else { return }
        lastLevelHost = now
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(max(count, 1)))
        let db = 20 * log10(max(rms, 0.000_01))
        onLevel(max(0, min(1, (db + 55) / 55)))
    }
}

enum Log {
    static let app = Logger(subsystem: "com.askscottpierce.cf-recorder", category: "app")
}

enum SpeechAssets {
    /// Finds the closest supported locale and downloads the on-device model if needed.
    static func ensureInstalled(for locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "CFRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "On-device transcription doesn't support \(locale.identifier) yet."
            ])
        }
        let probe = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        // Without a reservation the download fails with a bare `_GenericObjCError 0`.
        if await AssetInventory.status(forModules: [probe]) != .installed {
            _ = try await AssetInventory.reserve(locale: supported)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            progress("Getting the \(supported.identifier) speech model ready…")
            try await request.downloadAndInstall()
        }
        return supported
    }
}
