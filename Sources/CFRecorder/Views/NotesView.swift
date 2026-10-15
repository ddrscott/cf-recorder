import AppKit
import SwiftUI

struct NotesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionHeader(title: "Notes")
                if model.notesRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.meeting?.notes ?? "", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy notes as Markdown")
                    .disabled(model.meeting?.notes.isEmpty ?? true)
                Button(model.meeting?.notes.isEmpty == false ? "Regenerate" : "Generate") {
                    model.generateNotes()
                }
                .disabled(model.notesRunning || (model.meeting?.utterances.isEmpty ?? true))
            }
            .buttonStyle(.borderless)
            .font(Theme.mono(11))
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.notesError {
                        Text(error)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Rectangle().strokeBorder(Theme.orange.opacity(0.5)))
                    }
                    if let notes = model.meeting?.notes, !notes.isEmpty {
                        NotesMarkdown(text: notes) { model.toggleActionItem(line: $0) }
                    } else if !model.notesRunning {
                        Text(model.isRecording
                             ? "Notes and action items show up here as the call goes."
                             : "Hit Generate to write notes and action items from the transcript.")
                            .font(Theme.mono(12)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Just enough Markdown for the notes format: headings, bullets, and checkable action items.
struct NotesMarkdown: View {
    let text: String
    let onToggle: (Int) -> Void

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                row(line, index: index)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ raw: String, index: Int) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            SectionHeader(title: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                .padding(.top, index == 0 ? 0 : 12)
        } else if line.hasPrefix("- [ ]") || line.lowercased().hasPrefix("- [x]") {
            let done = !line.hasPrefix("- [ ]")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { onToggle(index) } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Theme.orange : .secondary)
                }
                .buttonStyle(.plain)
                inline(String(line.dropFirst(5)))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("–").foregroundStyle(Theme.orange)
                inline(String(line.dropFirst(2)))
            }
        } else if line.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: s.trimmingCharacters(in: .whitespaces), options: options))
            ?? AttributedString(s)
        return Text(attributed).font(.system(size: 13))
    }
}
