import Foundation

enum Speaker: String, Codable, Sendable {
    case me, them
}

struct Utterance: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var speaker: Speaker
    var text: String
    var start: Double
    var end: Double
}

/// Everything saved for one call. Lives in `<library>/<folder>/meeting.json`, next to
/// `me.m4a`, `them.m4a`, `transcript.md`, and `notes.md`.
struct Meeting: Codable, Sendable {
    var title: String
    /// The last title the notes suggested. While `title` still matches it (or is empty),
    /// new notes may retitle the call; once you type your own, they leave it alone.
    var autoTitle: String?
    var theirName: String
    var myName: String
    var startedAt: Date
    var duration: Double = 0
    var utterances: [Utterance] = []
    var notes: String = ""

    mutating func suggestTitle(_ suggested: String) {
        guard title.isEmpty || title == autoTitle else { return }
        title = suggested
        autoTitle = suggested
    }

    func name(for speaker: Speaker) -> String {
        speaker == .me ? myName : theirName
    }

    /// Inserts by start time, since the two streams finalize out of order.
    mutating func insert(_ utterance: Utterance) {
        let index = utterances.lastIndex { $0.start <= utterance.start }.map { $0 + 1 } ?? 0
        utterances.insert(utterance, at: index)
    }

    /// Plain text for the LLM and the .md file, with consecutive lines from the same
    /// speaker run together.
    func transcriptText() -> String {
        var lines: [String] = []
        var last: Speaker?
        for u in utterances where !u.text.isEmpty {
            if u.speaker == last, !lines.isEmpty {
                lines[lines.count - 1] += " " + u.text
            } else {
                lines.append("[\(Clock.format(u.start))] \(name(for: u.speaker)): \(u.text)")
            }
            last = u.speaker
        }
        return lines.joined(separator: "\n")
    }

    func transcriptMarkdown() -> String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        return "# \(title.isEmpty ? "Meeting" : title)\n\n\(date) · \(myName) and \(theirName)\n\n"
            + transcriptText().replacingOccurrences(of: "\n", with: "\n\n") + "\n"
    }
}

enum Clock {
    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct MeetingSummary: Identifiable, Hashable {
    var id: URL { folder }
    let folder: URL
    let title: String
    let startedAt: Date
    let duration: Double
}

enum MeetingStore {
    static let library: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Recorder", isDirectory: true)
        // Calls used to live in "CF Recorder"; carry them over once.
        let old = docs.appendingPathComponent("CF Recorder", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: folder.path) {
            try? fm.moveItem(at: old, to: folder)
        }
        return folder
    }()

    static func newFolder(for date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let folder = library.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func save(_ meeting: Meeting, to folder: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
            try meeting.transcriptMarkdown().write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            if !meeting.notes.isEmpty {
                try meeting.notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            }
        } catch {
            Log.app.error("Saving \(folder.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    static func load(_ folder: URL) -> Meeting? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
        return try? decoder.decode(Meeting.self, from: data)
    }

    static func list() -> [MeetingSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return folders.compactMap { folder in
            guard let m = load(folder) else { return nil }
            return MeetingSummary(folder: folder, title: m.title, startedAt: m.startedAt, duration: m.duration)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
