import AVFoundation
import Foundation

/// `CFRecorder transcribe <audio-file>...` prints `[mm:ss] text` lines to stdout.
/// It runs the same pipeline the app uses, so it doubles as a smoke test.
enum TranscribeCommand {
    static func run(_ paths: [String]) async -> Int32 {
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("usage: CFRecorder transcribe <audio-file>...\n".utf8))
            return 64
        }
        do {
            let locale = try await SpeechAssets.ensureInstalled(for: .current) { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            for path in paths {
                try await transcribe(URL(fileURLWithPath: path), locale: locale)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("transcribe: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func transcribe(_ url: URL, locale: Locale) async throws {
        let file = try AVAudioFile(forReading: url)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cf-recorder-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stream = StreamTranscriber(
            speaker: .them,
            sessionStartHost: mach_absolute_time(),
            fileURL: scratch,
            onUpdate: { update in
                guard update.isFinal, !update.text.isEmpty else { return }
                print("[\(Clock.format(update.start))] \(update.text)")
                fflush(stdout)
            },
            onLevel: { _ in }
        )
        try await stream.prepare(locale: locale)

        // Feed it in 100ms slices, the way live capture would.
        let format = file.processingFormat
        let slice = AVAudioFrameCount(format.sampleRate / 10)
        // AVAudioFile throws instead of returning zero frames at the end.
        while file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: slice) {
            try file.read(into: buffer, frameCount: slice)
            stream.ingest(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        }
        await stream.finish()
    }
}
