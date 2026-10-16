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
    /// Trash changes not yet sent to the server, call id → SyncClient.TrashAction.
    static let pendingTrash = "pendingTrash"

    static func register() {
        UserDefaults.standard.register(defaults: [
            myName: "Me",
            theirName: "Them",
            notesEngine: NotesEngine.apple.rawValue,
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
    var trash: [MeetingSummary] = []
    var showingTrash = false
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
    private var lastFullSync = Date.distantPast
    /// Asked once per connection; see `SyncClient.hasTrash`.
    private var serverHasTrash: Bool?

    init() {
        Prefs.register()
        _ = MeetingStore.emptyExpiredTrash()
        refreshHistory()
        select(history.first?.folder)
        // Backfill anything recorded while sync was off or the network was down.
        if syncConnected && Prefs.bool(Prefs.autoSync) { syncAll() }
        // Coming back to the app picks up calls trashed or restored on the web.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.syncConnected, Prefs.bool(Prefs.autoSync),
                      Date().timeIntervalSince(self.lastFullSync) > 60 else { return }
                self.syncAll()
            }
        }
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
        let engine = NotesEngine(rawValue: Prefs.string(Prefs.notesEngine)) ?? .apple
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
        trash = MeetingStore.listTrash()
    }

    var isTrashed: Bool { folder.map(MeetingStore.isTrashed) ?? false }

    // MARK: Trash

    /// Moves a call to the Trash, here and on the server.
    func trash(_ folder: URL) {
        guard folder != self.folder || !isBusy else { return }
        do {
            try MeetingStore.moveToTrash(folder)
        } catch {
            Log.app.error("Trashing \(folder.lastPathComponent) failed: \(error.localizedDescription)")
            return
        }
        if folder == self.folder {
            self.folder = nil
            meeting = nil
        }
        refreshHistory()
        mirror(.trash, folder)
    }

    func restore(_ folder: URL) {
        let restored: URL
        do {
            restored = try MeetingStore.restore(folder)
        } catch {
            Log.app.error("Restoring \(folder.lastPathComponent) failed: \(error.localizedDescription)")
            return
        }
        if folder == self.folder { self.folder = restored }
        refreshHistory()
        if showingTrash && trash.isEmpty { showingTrash = false }
        mirror(.restore, folder)
    }

    func deleteForever(_ folder: URL) {
        guard MeetingStore.isTrashed(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
        if folder == self.folder {
            self.folder = nil
            meeting = nil
        }
        refreshHistory()
        mirror(.purge, folder)
    }

    func emptyTrash() {
        for item in trash { deleteForever(item.folder) }
    }

    /// Queues the change for the server and sends it. The queue survives quitting and
    /// going offline, and goes out before the next sync looks at the server's trash.
    private func mirror(_ action: SyncClient.TrashAction, _ folder: URL) {
        guard syncConnected else { return }
        var pending = UserDefaults.standard.dictionary(forKey: Prefs.pendingTrash) as? [String: String] ?? [:]
        pending[folder.lastPathComponent] = action.rawValue
        UserDefaults.standard.set(pending, forKey: Prefs.pendingTrash)
        guard Prefs.bool(Prefs.autoSync) else { return }
        let restored = action == .restore ? [MeetingStore.library.appendingPathComponent(folder.lastPathComponent)] : []
        Task { await runSync(restored) }
    }

    private func sendPendingTrash() async throws {
        let pending = UserDefaults.standard.dictionary(forKey: Prefs.pendingTrash) as? [String: String] ?? [:]
        for (id, raw) in pending {
            if let action = SyncClient.TrashAction(rawValue: raw) {
                try await SyncClient.apply(action, id: id)
            }
            // Only clear it if nothing newer was queued for this call meanwhile.
            var now = UserDefaults.standard.dictionary(forKey: Prefs.pendingTrash) as? [String: String] ?? [:]
            if now[id] == raw { now[id] = nil }
            UserDefaults.standard.set(now, forKey: Prefs.pendingTrash)
        }
    }

    /// Follows trash changes made on the server (from the web viewer): calls it trashed
    /// move to the Trash here, and calls it restored move back. Runs after our own
    /// pending changes went out, so the server's state is the newest word.
    private func pullTrash() async throws {
        let remote = try await SyncClient.remoteCalls()
        let pending = UserDefaults.standard.dictionary(forKey: Prefs.pendingTrash) as? [String: String] ?? [:]
        // A call that's open and busy (recording, writing notes) stays where it is for now.
        let pinned = isBusy || notesRunning ? folder : nil
        for item in MeetingStore.list() {
            let id = item.folder.lastPathComponent
            guard remote.trashed.contains(id), pending[id] == nil, item.folder != pinned,
                  let moved = try? MeetingStore.moveToTrash(item.folder) else { continue }
            if item.folder == folder { folder = moved }
        }
        for item in MeetingStore.listTrash() {
            let id = item.folder.lastPathComponent
            guard remote.live.contains(id), pending[id] == nil,
                  let restored = try? MeetingStore.restore(item.folder) else { continue }
            if item.folder == folder { folder = restored }
        }
        refreshHistory()
    }

    // MARK: Sync

    /// Pushes the open call after a pause. While it's recording, only the transcript goes
    /// (every 30 seconds), since the audio files are still being written.
    func syncSoon(after seconds: Double = 3) {
        guard syncConnected, Prefs.bool(Prefs.autoSync), let folder, !MeetingStore.isTrashed(folder) else { return }
        let recording = isRecording
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(recording ? 30 : seconds))
            guard !Task.isCancelled else { return }
            await self?.runSync([folder])
        }
    }

    /// Sends pending trash changes, follows the server's, then pushes every call.
    func syncAll() {
        lastFullSync = Date()
        Task { await runSync([], everything: true) }
    }

    func syncConnectionChanged() {
        syncConnected = SyncClient.session != nil
        serverHasTrash = nil
        syncStatus = syncConnected ? "" : "not connected"
        if syncConnected { syncAll() }
    }

    private func runSync(_ folders: [URL], everything: Bool = false) async {
        while syncing { try? await Task.sleep(for: .milliseconds(250)) }
        syncing = true
        defer { syncing = false }
        syncStatus = "syncing…"
        do {
            // A server without a trash would take a DELETE as "delete forever", so trash
            // changes wait (still queued) until it has one.
            if serverHasTrash != true { serverHasTrash = try await SyncClient.hasTrash() }
            let hasTrash = serverHasTrash == true
            if hasTrash { try await sendPendingTrash() }
            var folders = folders
            if everything {
                if hasTrash { try await pullTrash() }
                folders = history.map(\.folder)
            }
            for f in folders where !MeetingStore.isTrashed(f) && FileManager.default.fileExists(atPath: f.path) {
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
