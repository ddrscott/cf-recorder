import Foundation

/// `CFRecorder notes [--apple] < transcript.txt` writes Markdown notes to stdout.
/// Reads `[mm:ss] Name: text` lines (what `transcribe` and transcript.md produce) and
/// uses the same engine settings as the app.
enum NotesCommand {
    static func run(_ args: [String]) async -> Int32 {
        Prefs.register()
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("usage: CFRecorder notes [--apple] < transcript.txt\n".utf8))
            return 64
        }

        var meeting = Meeting(
            title: "", theirName: Prefs.string(Prefs.theirName),
            myName: Prefs.string(Prefs.myName), startedAt: Date()
        )
        meeting.utterances = [Utterance(speaker: .them, text: input, start: 0, end: 0)]
        let engine: NotesEngine = args.contains("--apple") ? .apple
            : NotesEngine(rawValue: Prefs.string(Prefs.notesEngine)) ?? .ollama

        var printed = ""
        do {
            try await NotesGenerator.generate(
                meeting, engine: engine,
                ollamaHost: Prefs.string(Prefs.ollamaHost),
                ollamaModel: Prefs.string(Prefs.ollamaModel),
                rawTranscript: input
            ) { text in
                // Stream to stdout as it arrives; status lines like "_Reading part 2…_" get replaced, so skip them.
                guard text.hasPrefix(printed) else { return }
                print(text.dropFirst(printed.count), terminator: "")
                fflush(stdout)
                printed = text
            }
            print()
            return 0
        } catch {
            FileHandle.standardError.write(Data("notes: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
