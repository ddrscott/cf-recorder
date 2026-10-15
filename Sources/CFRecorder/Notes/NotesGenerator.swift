import Foundation
import FoundationModels

enum NotesEngine: String, CaseIterable, Identifiable {
    case ollama, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ollama: "Ollama (local)"
        case .apple: "Apple Intelligence (on-device)"
        }
    }
}

enum NotesGenerator {
    static func instructions(myName: String, theirName: String) -> String {
        """
        You write meeting notes from a call between \(myName) and \(theirName). \
        \(myName) is the person you're writing for. The transcript came from speech \
        recognition, so expect some misheard words; infer the obvious intent but never \
        invent facts, names, numbers, or dates that aren't there.

        Reply in Markdown with exactly these sections, in this order:

        ## Summary
        Three to five plain sentences on what the call was about and where it landed.

        ## Key Points
        - Short bullets of the substance discussed.

        ## Decisions
        - What was agreed. Write "None" if nothing was.

        ## Action Items
        - [ ] **Owner** — the task, with any due date that was said out loud.
        Use \(myName) or \(theirName) as the owner, or **Unassigned**.

        ## Open Questions
        - Anything left unresolved. Write "None" if nothing was.

        Keep it tight. No preamble, no closing remarks.
        """
    }

    static let titleInstructions = """
        Name this call in three to seven words, the way you'd label a folder: what it was \
        about, like "Q3 pricing review" or "Laptop refresh vendor shortlist". Leave out the people on \
        the call; every call has them. No date, no quotes, no trailing period. Reply \
        with the title and nothing else.
        """

    /// A short title for the call, written from its finished notes (they're small, so
    /// this is quick on either engine). Nil when the model has nothing usable.
    static func title(
        notes: String, engine: NotesEngine, ollamaHost: String, ollamaModel: String
    ) async throws -> String? {
        let prompt = "Meeting notes:\n\n\(notes)"
        let raw: String
        switch engine {
        case .apple:
            let session = LanguageModelSession(instructions: titleInstructions)
            raw = try await session.respond(to: prompt).content
        case .ollama:
            guard let url = URL(string: ollamaHost.trimmingCharacters(in: .whitespaces) + "/api/chat") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": ollamaModel,
                "stream": false,
                "options": ["temperature": 0.2],
                "messages": [
                    ["role": "system", "content": titleInstructions],
                    ["role": "user", "content": prompt],
                ],
            ] as [String: Any])
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            raw = ((json?["message"] as? [String: Any])?["content"] as? String) ?? ""
        }
        let line = stripThinking(raw)
            .split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let title = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*_\"'`. ").union(.whitespaces))
        return title.isEmpty || title.count > 80 ? nil : title
    }

    /// Streams the notes in; `onText` gets the full text so far each time.
    static func generate(
        _ meeting: Meeting,
        engine: NotesEngine,
        ollamaHost: String,
        ollamaModel: String,
        rawTranscript: String? = nil,
        onText: @escaping @MainActor (String) -> Void
    ) async throws {
        let system = instructions(myName: meeting.myName, theirName: meeting.theirName)
        let transcript = rawTranscript ?? meeting.transcriptText()
        guard !transcript.isEmpty else { return }
        switch engine {
        case .ollama:
            try await ollama(system: system, transcript: transcript, host: ollamaHost, model: ollamaModel, onText: onText)
        case .apple:
            try await apple(system: system, transcript: transcript, onText: onText)
        }
    }

    private static func ollama(
        system: String, transcript: String, host: String, model: String,
        onText: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let url = URL(string: host.trimmingCharacters(in: .whitespaces) + "/api/chat") else {
            throw NotesError("The Ollama host \"\(host)\" isn't a valid URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "options": ["num_ctx": 32768, "temperature": 0.2],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "Transcript:\n\n\(transcript)"],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw NotesError("Couldn't reach Ollama at \(host). Is `ollama serve` running?")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw NotesError("Ollama said \(http.statusCode): \(detail)")
        }

        var text = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let error = chunk["error"] as? String { throw NotesError("Ollama: \(error)") }
            if let message = chunk["message"] as? [String: Any], let piece = message["content"] as? String {
                text += piece
                let snapshot = stripThinking(text)
                await onText(snapshot)
            }
        }
    }

    /// The on-device model has a small context window, so long calls are summarized in
    /// chunks first and the final notes are written from those.
    private static func apple(
        system: String, transcript: String,
        onText: @escaping @MainActor (String) -> Void
    ) async throws {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw NotesError("Apple Intelligence isn't available on this Mac. Turn it on in System Settings, or switch to Ollama.")
        }

        let chunkLimit = 6_000
        var source = transcript
        if transcript.count > chunkLimit {
            var partials: [String] = []
            for (i, chunk) in chunks(of: transcript, limit: chunkLimit).enumerated() {
                await onText("_Reading part \(i + 1) of the call…_")
                let session = LanguageModelSession(instructions: "Condense this part of a call transcript into dense factual bullets. Keep every commitment, owner, date, number, and decision.")
                partials.append(try await session.respond(to: chunk).content)
            }
            source = partials.joined(separator: "\n")
        }

        let session = LanguageModelSession(instructions: system)
        var latest = ""
        for try await snapshot in session.streamResponse(to: "Transcript:\n\n\(source)") {
            latest = snapshot.content
            await onText(latest)
        }
    }

    private static func chunks(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Reasoning models sometimes lead with a <think> block; it doesn't belong in the notes.
    private static func stripThinking(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        guard let close = text.range(of: "</think>") else { return "_Thinking…_" }
        return String(text[..<open.lowerBound] + text[close.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NotesError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
