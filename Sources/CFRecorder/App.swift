import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let rest = Array(args.dropFirst())
        switch args.first {
        case "transcribe": Task { exit(await TranscribeCommand.run(rest)) }
        case "notes": Task { exit(await NotesCommand.run(rest)) }
        case "sync": Task { exit(await SyncCommand.run(rest)) }
        case "devices":
            // Input devices as `uid<TAB>name`, the UIDs Settings stores.
            for d in AudioDevices.inputs() { print("\(d.uid)\t\(d.name)") }
            exit(0)
        default:
            CFRecorderApp.main()
            return
        }
        dispatchMain()
    }
}

struct CFRecorderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("CF Recorder", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            // Fit the screen it opens on rather than spilling onto the next display.
            let visible = context.defaultDisplay.visibleRect
            let size = CGSize(
                width: min(1280, visible.width - 80),
                height: min(820, visible.height - 60)
            )
            return WindowPlacement(.center, size: size)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "Start Recording") {
            model.toggleRecording()
        }
        .disabled(model.phase != .idle && model.phase != .recording)
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit CF Recorder") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
