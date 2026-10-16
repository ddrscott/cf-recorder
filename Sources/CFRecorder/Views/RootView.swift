import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showNotes") private var showNotes = true
    @AppStorage("showCalls") private var showCalls = true

    // Plain columns instead of NavigationSplitView: the split view lays itself out at
    // its content's ideal width, which overflows smaller windows.
    var body: some View {
        HStack(spacing: 0) {
            if showCalls {
                Sidebar().frame(width: 230)
                Divider()
            }
            Group {
                if model.meeting != nil {
                    MeetingView()
                } else {
                    EmptyState()
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            if showNotes && model.meeting != nil {
                Divider()
                NotesView().frame(width: 360)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showCalls.toggle() } label: {
                    Label("Calls", systemImage: "sidebar.leading")
                }
                .help("Show or hide past calls")
            }
            ToolbarItem(placement: .primaryAction) { RecordButton() }
            ToolbarItem(placement: .primaryAction) {
                Button { showNotes.toggle() } label: {
                    Label("Notes", systemImage: "sidebar.trailing")
                }
                .help("Show or hide notes")
            }
        }
        .alert("Couldn't start recording", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            switch model.phase {
            case .idle:
                Label("Record", systemImage: "record.circle")
            case .preparing, .finishing:
                ProgressView().controlSize(.small)
            case .recording:
                Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(Theme.orange)
            }
        }
        .help(model.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
        .disabled(model.phase != .idle && model.phase != .recording)
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEmpty = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: model.showingTrash ? "Trash" : "Calls")
                Spacer()
                Button {
                    model.showingTrash.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.showingTrash ? "arrow.uturn.backward" : "trash")
                        if !model.showingTrash && !model.trash.isEmpty {
                            Text("\(model.trash.count)").font(Theme.mono(10))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(model.showingTrash ? "Back to calls" : "Show the Trash")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.showingTrash {
                        Text("Calls here are deleted for good \(MeetingStore.trashDays) days after you trash them. Restoring one puts it back on the web too.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        if model.trash.isEmpty {
                            Text("The Trash is empty.").font(Theme.mono(11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        ForEach(model.trash) { item in
                            row(item)
                        }
                    } else {
                        ForEach(model.history) { item in
                            row(item)
                        }
                    }
                }
                .padding(8)
            }
            if model.showingTrash && !model.trash.isEmpty {
                Divider()
                Button("Empty Trash…") { confirmEmpty = true }
                    .buttonStyle(.borderless).font(Theme.mono(11))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .confirmationDialog("Delete \(model.trash.count) call\(model.trash.count == 1 ? "" : "s") for good?",
                                        isPresented: $confirmEmpty) {
                        Button("Delete Forever", role: .destructive) { model.emptyTrash() }
                    } message: {
                        Text("They're deleted from this Mac and the server, and can't be restored.")
                    }
            }
            if model.syncConnected {
                Divider()
                HStack(spacing: 6) {
                    Text("//").foregroundStyle(Theme.orange)
                    Text(model.syncStatus.isEmpty ? "sync on" : model.syncStatus)
                        .lineLimit(1).truncationMode(.tail)
                        .help(model.syncStatus)
                }
                .font(Theme.mono(10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .disabled(model.isBusy || model.notesRunning)
    }

    private func row(_ item: MeetingSummary) -> some View {
        let selected = item.folder == model.folder
        return Button { model.select(item.folder) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if model.isRecording && selected {
                        Text("$").foregroundStyle(Theme.orange).font(Theme.mono(12, weight: .bold))
                    }
                    Text(item.title.isEmpty ? "Untitled call" : item.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                Text("\(item.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(Clock.format(item.duration))")
                    .font(Theme.mono(10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.orange.opacity(0.12) : .clear)
            .overlay(Rectangle().strokeBorder(selected ? Theme.orange.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.folder])
            }
            if item.trashedAt != nil || MeetingStore.isTrashed(item.folder) {
                Button("Restore") { model.restore(item.folder) }
                Button("Delete Forever", role: .destructive) { model.deleteForever(item.folder) }
            } else {
                Button("Move to Trash", role: .destructive) { model.trash(item.folder) }
                    .disabled(model.isBusy && selected)
            }
        }
    }
}

struct MeetingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let meeting = model.meeting {
                header(meeting)
                Divider()
            }
            if model.isTrashed, let folder = model.folder {
                HStack(spacing: 8) {
                    Text("//").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.orange)
                    Text("IN_TRASH").font(Theme.mono(11, weight: .semibold))
                    Text("Deleted for good \(MeetingStore.trashDays) days after it was trashed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.restore(folder)
                    } label: {
                        HStack(spacing: 5) {
                            Text("$").foregroundStyle(Theme.orange)
                            Text("restore")
                        }
                        .font(Theme.mono(11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Rectangle().strokeBorder(Theme.orange, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.orange.opacity(0.5)), alignment: .bottom)
            }
            if let warning = model.captureWarning {
                HStack(spacing: 8) {
                    Text("!").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.orange)
                    Text(warning).font(Theme.mono(11))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.orange.opacity(0.12))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.orange.opacity(0.5)), alignment: .bottom)
            }
            TranscriptView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Untitled call", text: Binding(
                    get: { model.meeting?.title ?? "" },
                    set: { model.meeting?.title = $0; model.scheduleSave() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))

                HStack(spacing: 4) {
                    Text("with").foregroundStyle(.secondary)
                    TextField("Them", text: Binding(
                        get: { model.meeting?.theirName ?? "" },
                        set: { model.meeting?.theirName = $0; model.scheduleSave() }
                    ))
                    .textFieldStyle(.plain)
                    .fixedSize()
                    Text("· \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(Theme.mono(11))
            }
            Spacer()
            if model.isRecording {
                VStack(alignment: .trailing, spacing: 5) {
                    LevelMeter(label: "THEM", level: model.levels[.them] ?? 0)
                    LevelMeter(label: "  ME", level: model.levels[.me] ?? 0)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(Theme.orange)
                        Text("REC \(Clock.format(context.date.timeIntervalSince(meeting.startedAt)))")
                    }
                    .font(Theme.mono(15, weight: .semibold))
                }
            } else if case .preparing(let message) = model.phase {
                Text(message).font(Theme.mono(11)).foregroundStyle(.secondary)
            } else if model.phase == .finishing {
                Text("Finishing the transcript…").font(Theme.mono(11)).foregroundStyle(.secondary)
            } else {
                Button("Show in Finder") { model.revealInFinder() }
                    .buttonStyle(.borderless).font(Theme.mono(11))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Ready")
            if case .preparing(let message) = model.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(Theme.mono(12))
                }
            } else {
                Text("Put your headset on and hit ⌘R.")
                    .font(.system(size: 20, weight: .semibold))
                Text("Your mic and everything you hear get recorded as two separate tracks, transcribed on this Mac as you talk, and turned into notes and action items when you stop.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440, alignment: .leading)
                Button {
                    model.toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(Theme.orange)
                        Text("record")
                    }
                    .font(Theme.mono(13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay(Rectangle().strokeBorder(Theme.orange, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
