import AVFoundation
import os

/// `miccheck [seconds] [mic-uid] [--save dir]`: opens the mic and the desktop tap the way
/// a call does and prints, once a second, how many buffers each delivered and how loud
/// they were. With `--save`, both streams also run through the call pipeline: the m4a
/// files land in `dir`, the final transcript lines print as they arrive, and at the end
/// it lists the "me" lines the app would drop as echoes of the guest.
/// Run it through `open` so macOS checks Recorder's mic permission, not the terminal's:
///
///     open -W -a build/Recorder.app --args miccheck 8 --out /tmp/miccheck.txt
enum MicCheck {
    static func run(_ args: [String]) async -> Int32 {
        var rest = args
        var out: FileHandle?
        if let i = rest.firstIndex(of: "--out"), i + 1 < rest.count {
            FileManager.default.createFile(atPath: rest[i + 1], contents: nil)
            out = FileHandle(forWritingAtPath: rest[i + 1])
            rest.removeSubrange(i...i + 1)
        }
        func say(_ line: String) {
            print(line)
            out?.write(Data((line + "\n").utf8))
        }
        var saveDir: URL?
        if let i = rest.firstIndex(of: "--save"), i + 1 < rest.count {
            saveDir = URL(fileURLWithPath: rest[i + 1], isDirectory: true)
            rest.removeSubrange(i...i + 1)
        }
        let seconds = rest.first.flatMap(Int.init) ?? 8
        let device = rest.count > 1 ? AudioDevices.device(uid: rest[1]) : nil

        do { try await MicCapture.requestAccess() } catch {
            say("mic: \(error.localizedDescription)")
            return 1
        }
        let stats = OSAllocatedUnfairLock(initialState: [Speaker.me: (0, Float(0)), .them: (0, Float(0))])
        func tally(_ speaker: Speaker, _ buffer: AVAudioPCMBuffer) {
            guard let samples = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
            stats.withLock { s in
                let (n, p) = s[speaker]!
                s[speaker] = (n + 1, max(p, peak))
            }
        }

        var streams: [Speaker: StreamTranscriber] = [:]
        let finals = OSAllocatedUnfairLock(initialState: [Utterance]())
        if let saveDir {
            do {
                try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
                let locale = try await SpeechAssets.ensureInstalled(for: .current) { _ in }
                let host = mach_absolute_time()
                for speaker in [Speaker.me, .them] {
                    let stream = StreamTranscriber(
                        speaker: speaker, sessionStartHost: host,
                        fileURL: saveDir.appendingPathComponent("\(speaker.rawValue).m4a"),
                        onUpdate: { u in
                            guard u.isFinal, !u.text.isEmpty else { return }
                            say("[\(Clock.format(u.start))] \(u.speaker.rawValue): \(u.text)")
                            finals.withLock { $0.append(Utterance(speaker: u.speaker, text: u.text, start: u.start, end: u.end)) }
                        },
                        onLevel: { _ in }
                    )
                    try await stream.prepare(locale: locale)
                    streams[speaker] = stream
                }
            } catch {
                say("transcriber: \(error.localizedDescription)")
                return 1
            }
        }
        let me = streams[.me], them = streams[.them]

        say("mic: \(device?.name ?? "System Default")")
        let mic = MicCapture(device: device)
        let system = SystemAudioCapture()
        do {
            try mic.start { buffer, time in tally(.me, buffer); me?.ingest(buffer, at: time) }
            try system.start { buffer, time in tally(.them, buffer); them?.ingest(buffer, at: time) }
        } catch {
            say("start: \(error.localizedDescription)")
            return 1
        }
        func db(_ peak: Float) -> String { peak > 0 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "silent" }
        for t in 1...seconds {
            try? await Task.sleep(for: .seconds(1))
            let s = stats.withLock { s in
                defer { s[.me] = (s[.me]!.0, 0); s[.them] = (s[.them]!.0, 0) }
                return s
            }
            say("t=\(t)s  mic \(s[.me]!.0) buffers, \(db(s[.me]!.1))  |  desktop \(s[.them]!.0) buffers, \(db(s[.them]!.1))")
        }
        mic.stop()
        system.stop()
        for stream in streams.values { await stream.finish() }
        if saveDir != nil {
            var meeting = Meeting(title: "", theirName: "them", myName: "me", startedAt: Date())
            for u in finals.withLock({ $0 }) { meeting.insert(u) }
            let mine = meeting.utterances.filter { $0.speaker == .me }
            let echoes = mine.filter(meeting.isEcho)
            say("echo: \(echoes.count) of \(mine.count) mic lines would be dropped")
            for e in echoes { say("  [\(Clock.format(e.start))] \(e.text)") }
        }
        return 0
    }
}
