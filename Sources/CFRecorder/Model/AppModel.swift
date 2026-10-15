import AVFoundation
import AppKit
import Foundation
import Observation

enum Prefs {
    static let myName = "myName"
    static let theirName = "theirName"
    static let notesEngine = "notesEngine"
    static let ollamaHost = "ollamaHost"
    static let ollamaModel = "ollamaModel"
    static let liveNotes = "liveNotes"
    static let notesOnStop = "notesOnStop"
    static let autoSync = "autoSync"
    /// Input device UIDs; empty means the system default.
    static let micDevice = "micDevice"
    static let guestIsDesktop = "guestIsDesktop"
    static let guestDevice = "guestDevice"

    static func register() {
        UserDefaults.standard.register(defaults: [
            myName: "Me",
            theirName: "Them",
            notesEngine: NotesEngine.ollama.rawValue,
            ollamaHost: "http://localhost:11434",
            ollamaModel: "gemma4:12b-mlx",
            liveNotes: true,
            notesOnStop: true,
            autoSync: true,
            micDevice: "",
            guestIsDesktop: true,
            guestDevice: "",
        ])
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing
    }

    var phase: Phase = .idle
    var meeting: Meeting?
    var folder: URL?
    var volatile: [Speaker: Utterance] = [:]
    var levels: [Speaker: Float] = [.me: 0, .them: 0]
    var history: [MeetingSummary] = []
    var errorMessage: String?
    var notesRunning = false
    var notesError: String?
    /// Shown in the header while recording when one side has gone quiet at the source.
    var captureWarning: String?
    var syncStatus = ""
    var syncConnected = SyncClient.session != nil

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle }

    private var mic: MicCapture?
    private var guestMic: MicCapture?
    private var system: SystemAudioCapture?
    private var streams: [StreamTranscriber] = []
    private var liveNotesTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var notedUtteranceCount = 0
    private var syncTask: Task<Void, Never>?
    private var syncing = false

    init() {
        Prefs.register()
        refreshHistory()
        select(history.first?.folder)
        // Backfill anything recorded while sync was off or the network was down.
        if syncConnected && Prefs.bool(Prefs.autoSync) { syncAll() }
    }

    // MARK: Recording

    func toggleRecording() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    func start() async {
        guard phase == .idle else { return }
        errorMessage = nil
        notesError = nil
        notesTask?.cancel()
        do {
            phase = .preparing("Checking microphone access…")
            try await MicCapture.requestAccess()
            let sources = try Self.audioSources()

            phase = .preparing("Loading the on-device speech model…")
            let locale = try await SpeechAssets.ensureInstalled(for: .current) { message in
                Task { @MainActor in self.phase = .preparing(message) }
            }

            let now = Date()
            let folder = try MeetingStore.newFolder(for: now)
            self.folder = folder
            meeting = Meeting(
                title: "",
                theirName: Prefs.string(Prefs.theirName),
                myName: Prefs.string(Prefs.myName),
                startedAt: now
            )
            volatile = [:]
            notedUtteranceCount = 0
            MeetingStore.save(meeting!, to: folder)
            refreshHistory()

            phase = .preparing("Starting the recognizers…")
            let startHost = mach_absolute_time()
            let me = makeStream(.me, startHost: startHost, file: folder.appendingPathComponent("me.m4a"))
            let them = makeStream(.them, startHost: startHost, file: folder.appendingPathComponent("them.m4a"))
            streams = [me, them]
            try await me.prepare(locale: locale)
            try await them.prepare(locale: locale)

            phase = .preparing("Opening audio…")
            let mic = MicCapture(device: sources.mic)
            try mic.start { buffer, time in me.ingest(buffer, at: time) }
            self.mic = mic
            if sources.guestIsDesktop {
                let system = SystemAudioCapture()
                try system.start { buffer, time in them.ingest(buffer, at: time) }
                self.system = system
            } else {
                let guest = MicCapture(device: sources.guest)
                try guest.start { buffer, time in them.ingest(buffer, at: time) }
                self.guestMic = guest
            }

            phase = .recording
            startLiveNotes()
            watchForSilence(me: me, them: them)
        } catch {
            errorMessage = error.localizedDescription
            await teardown()
            phase = .idle
        }
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .finishing
        captureWarning = nil
        liveNotesTask?.cancel()
        await teardown()
        volatile = [:]
        levels = [.me: 0, .them: 0]
        if var meeting, let folder {
            meeting.duration = Date().timeIntervalSince(meeting.startedAt)
            self.meeting = meeting
            MeetingStore.save(meeting, to: folder)
        }
        refreshHistory()
        phase = .idle
        syncSoon(after: 1)
        if Prefs.bool(Prefs.notesOnStop), meeting?.utterances.isEmpty == false {
            generateNotes()
        }
    }

    /// Resolves the device preferences. A device that's set but unplugged is an error
    /// rather than a quiet fallback, so a call never records the wrong mic.
    private static func audioSources() throws -> (mic: AudioDevice?, guestIsDesktop: Bool, guest: AudioDevice?) {
        let micUID = Prefs.string(Prefs.micDevice)
        let mic = AudioDevices.device(uid: micUID)
        if !micUID.isEmpty && mic == nil {
            throw CaptureError.setup("Your mic isn't connected. Plug it in or pick another in Settings → Audio.")
        }
        let desktop = Prefs.bool(Prefs.guestIsDesktop)
        if desktop { return (mic, true, nil) }
        let guestUID = Prefs.string(Prefs.guestDevice)
        guard let guest = AudioDevices.device(uid: guestUID) else {
            throw CaptureError.setup(guestUID.isEmpty
                ? "Pick the guest's input device in Settings → Audio, or record desktop audio as the guest."
                : "The guest's input device isn't connected. Plug it in or pick another in Settings → Audio.")
        }
        if guest.uid == (mic?.uid ?? "") {
            throw CaptureError.setup("Your mic and the guest's are the same device. Pick two different ones in Settings → Audio.")
        }
        return (mic, false, guest)
    }

    /// A stream that never delivers a buffer means the device isn't feeding us at all,
    /// which is different from a quiet room: say so instead of recording nothing.
    private func watchForSilence(me: StreamTranscriber, them: StreamTranscriber) {
        captureWarning = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isRecording else { return }
            if !me.hasAudio {
                self.captureWarning = "No audio from your mic. Check the input in System Settings → Sound, then restart the recording."
            } else if !them.hasAudio {
                self.captureWarning = Prefs.bool(Prefs.guestIsDesktop)
                    ? "No system audio is coming through. Check System Settings → Privacy & Security → Screen & System Audio Recording."
                    : "No audio from the guest's input device. Check that it's plugged in and not muted."
            }
        }
    }

    private func teardown() async {
        mic?.stop()
        guestMic?.stop()
        system?.stop()
        mic = nil
        guestMic = nil
        system = nil
        await withTaskGroup(of: Void.self) { group in
            for stream in streams { group.addTask { await stream.finish() } }
        }
        streams = []
    }

    private func makeStream(_ speaker: Speaker, startHost: UInt64, file: URL) -> StreamTranscriber {
        // DispatchQueue.main keeps updates in order, so a stale volatile result can't
        // land after the final one that replaced it.
        StreamTranscriber(
            speaker: speaker,
            sessionStartHost: startHost,
            fileURL: file,
            onUpdate: { [weak self] update in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
            },
            onLevel: { [weak self] level in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.levels[speaker] = level } }
            }
        )
    }

    private func apply(_ update: StreamTranscriber.Update) {
        guard meeting != nil else { return }
        let utterance = Utterance(speaker: update.speaker, text: update.text, start: update.start, end: update.end)
        if update.isFinal {
            volatile[update.speaker] = nil
            guard !update.text.isEmpty else { return }
            meeting?.insert(utterance)
            scheduleSave()
        } else {
            volatile[update.speaker] = update.text.isEmpty ? nil : utterance
        }
    }

    // MARK: Notes

    private func startLiveNotes() {
        liveNotesTask?.cancel()
        liveNotesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard let self, !Task.isCancelled, self.isRecording, Prefs.bool(Prefs.liveNotes) else { continue }
                let count = self.meeting?.utterances.count ?? 0
                if count >= 4, count != self.notedUtteranceCount, !self.notesRunning {
                    self.generateNotes()
                }
            }
        }
    }

    func generateNotes() {
        guard let snapshot = meeting, let folder, !notesRunning else { return }
        notesRunning = true
        notesError = nil
        notedUtteranceCount = snapshot.utterances.count
        let engine = NotesEngine(rawValue: Prefs.string(Prefs.notesEngine)) ?? .ollama
        let previous = snapshot.notes
        notesTask = Task {
            defer { notesRunning = false }
            do {
                try await NotesGenerator.generate(
                    snapshot,
                    engine: engine,
                    ollamaHost: Prefs.string(Prefs.ollamaHost),
                    ollamaModel: Prefs.string(Prefs.ollamaModel)
                ) { [weak self] text in
                    guard let self, self.folder == folder else { return }
                    self.meeting?.notes = text
                }
                guard self.folder == folder, let notes = meeting?.notes, !notes.isEmpty else { return }
                // A title is nice to have; failing to get one shouldn't fail the notes.
                if let title = try? await NotesGenerator.title(
                    notes: notes, engine: engine,
                    ollamaHost: Prefs.string(Prefs.ollamaHost),
                    ollamaModel: Prefs.string(Prefs.ollamaModel)
                ), self.folder == folder {
                    meeting?.suggestTitle(title)
                }
                if self.folder == folder, let meeting {
                    MeetingStore.save(meeting, to: folder)
                    refreshHistory()
                    syncSoon(after: 1)
                }
            } catch {
                if self.folder == folder {
                    notesError = error.localizedDescription
                    meeting?.notes = previous
                }
            }
        }
    }

    /// Flips `- [ ]` and `- [x]` on one line of the notes.
    func toggleActionItem(line index: Int) {
        guard var notes = meeting?.notes else { return }
        var lines = notes.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return }
        let line = lines[index]
        if line.contains("- [ ]") {
            lines[index] = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        } else if line.contains("- [x]") {
            lines[index] = line.replacingOccurrences(of: "- [x]", with: "- [ ]")
        }
        notes = lines.joined(separator: "\n")
        meeting?.notes = notes
        scheduleSave()
    }

    // MARK: Library

    func select(_ folder: URL?) {
        guard !isBusy, !notesRunning, folder != self.folder else { return }
        self.folder = folder
        meeting = folder.flatMap(MeetingStore.load)
        volatile = [:]
        notesError = nil
        errorMessage = nil
    }

    func refreshHistory() {
        history = MeetingStore.list()
    }

    func trash(_ folder: URL) {
        guard folder != self.folder || !isBusy else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        if folder == self.folder {
            self.folder = nil
            meeting = nil
        }
        refreshHistory()
    }

    // MARK: Sync

    /// Pushes the open call after a pause. While it's recording, only the transcript goes
    /// (every 30 seconds), since the audio files are still being written.
    func syncSoon(after seconds: Double = 3) {
        guard syncConnected, Prefs.bool(Prefs.autoSync), let folder else { return }
        let recording = isRecording
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(recording ? 30 : seconds))
            guard !Task.isCancelled else { return }
            await self?.runSync([folder])
        }
    }

    func syncAll() {
        Task { await runSync(history.map(\.folder)) }
    }

    func syncConnectionChanged() {
        syncConnected = SyncClient.session != nil
        syncStatus = syncConnected ? "" : "not connected"
        if syncConnected { syncAll() }
    }

    private func runSync(_ folders: [URL]) async {
        while syncing { try? await Task.sleep(for: .milliseconds(250)) }
        syncing = true
        defer { syncing = false }
        syncStatus = "syncing…"
        do {
            for f in folders {
                _ = try await SyncClient.sync(folder: f, skipAudio: isRecording && f == folder)
            }
            syncStatus = "synced \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            syncStatus = "sync failed: \(error.localizedDescription)"
            Log.app.error("Sync failed: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Debounced so editing the title or a stream of finals doesn't hammer the disk.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, let meeting = self.meeting, let folder = self.folder else { return }
            MeetingStore.save(meeting, to: folder)
            self.syncSoon()
            if let i = self.history.firstIndex(where: { $0.folder == folder }), self.history[i].title != meeting.title {
                self.refreshHistory()
            }
        }
    }
}
