import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.myName) private var myName = "Me"
    @AppStorage(Prefs.theirName) private var theirName = "Them"
    @AppStorage(Prefs.notesEngine) private var engine = NotesEngine.ollama.rawValue
    @AppStorage(Prefs.ollamaHost) private var ollamaHost = "http://localhost:11434"
    @AppStorage(Prefs.ollamaModel) private var ollamaModel = "gemma4:12b-mlx"
    @AppStorage(Prefs.liveNotes) private var liveNotes = true
    @AppStorage(Prefs.notesOnStop) private var notesOnStop = true
    @AppStorage(Prefs.autoSync) private var autoSync = true
    @AppStorage("syncServer") private var syncServer = SyncClient.defaultServer
    @State private var syncMessage = ""
    @State private var connecting = false

    @AppStorage(Prefs.micDevice) private var micDevice = ""
    @AppStorage(Prefs.guestIsDesktop) private var guestIsDesktop = true
    @AppStorage(Prefs.guestDevice) private var guestDevice = ""
    @State private var inputs: [AudioDevice] = []

    @State private var installedModels: [String] = []

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Audio", systemImage: "waveform") { audio }
            Tab("Notes", systemImage: "list.bullet.rectangle") { notes }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") { sync }
        }
        .frame(width: 480)
        .onAppear { inputs = AudioDevices.inputs() }
        .task(id: ollamaHost) { installedModels = await Self.ollamaModels(host: ollamaHost) }
    }

    private var general: some View {
        Form {
            Section("Names") {
                TextField("Your name", text: $myName)
                TextField("Default name for the other person", text: $theirName)
            }
            Section {
                LabeledContent("Recordings") {
                    Button(MeetingStore.library.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        try? FileManager.default.createDirectory(at: MeetingStore.library, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(MeetingStore.library)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var audio: some View {
        Form {
            Section {
                Picker("Your mic", selection: $micDevice) {
                    Text("System Default").tag("")
                    devices(keeping: micDevice)
                }
                Toggle("Record desktop audio as the guest", isOn: $guestIsDesktop)
                if !guestIsDesktop {
                    Picker("Guest's mic", selection: $guestDevice) {
                        Text("Choose a device").tag("")
                        devices(keeping: guestDevice)
                    }
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    Button("Refresh") { inputs = AudioDevices.inputs() }.buttonStyle(.link).font(.caption)
                }
            } footer: {
                Text(guestIsDesktop
                     ? "The guest is everything your Mac plays, like a Zoom or Meet call in your headset."
                     : "Two input devices at once, like a second mic for someone in the room. Each side is transcribed on its own.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var notes: some View {
        Form {
            Section {
                Picker("Engine", selection: $engine) {
                    ForEach(NotesEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if engine == NotesEngine.ollama.rawValue {
                    TextField("Ollama host", text: $ollamaHost)
                    if installedModels.isEmpty {
                        TextField("Model", text: $ollamaModel)
                    } else {
                        Picker("Model", selection: $ollamaModel) {
                            ForEach(Set(installedModels + [ollamaModel]).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Toggle("Refresh notes during the call", isOn: $liveNotes)
                Toggle("Write notes when recording stops", isOn: $notesOnStop)
            }
        }
        .formStyle(.grouped)
    }

    private var sync: some View {
        Form {
            Section {
                if let session = SyncClient.session, model.syncConnected {
                    LabeledContent("Server", value: session.server)
                    LabeledContent("Signed in as", value: session.email ?? "unknown")
                    Toggle("Sync calls automatically", isOn: $autoSync)
                    HStack {
                        Button("Sync All Now") { model.syncAll() }
                        Button("Disconnect") {
                            SyncClient.disconnect()
                            model.syncConnectionChanged()
                        }
                        Spacer()
                        Text(model.syncStatus).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    TextField("Server", text: $syncServer)
                    HStack {
                        Button(connecting ? "Waiting for the browser…" : "Connect") { connect() }
                            .disabled(connecting)
                        Spacer()
                        Text(syncMessage).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } footer: {
                Text("Any server that speaks the Recorder sync API works. You sign in once in your browser; the app keeps its token in the Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Listed devices, plus a remembered one that's unplugged so the picker can still show it.
    @ViewBuilder
    private func devices(keeping uid: String) -> some View {
        ForEach(inputs) { Text($0.name).tag($0.uid) }
        if !uid.isEmpty && !inputs.contains(where: { $0.uid == uid }) {
            Text("Not connected").tag(uid)
        }
    }

    private func connect() {
        connecting = true
        syncMessage = ""
        Task {
            do {
                _ = try await SyncClient.connect(server: syncServer) { line in
                    Task { @MainActor in syncMessage = line }
                }
                model.syncConnectionChanged()
                NSApp.activate()
            } catch {
                syncMessage = error.localizedDescription
            }
            connecting = false
        }
    }

    static func ollamaModels(host: String) async -> [String] {
        guard let url = URL(string: host + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }
    }
}
