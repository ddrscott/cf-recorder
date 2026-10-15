import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Transcript")
                Spacer()
                if let meeting = model.meeting {
                    Text("\(meeting.utterances.count) lines")
                        .font(Theme.mono(10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if let meeting = model.meeting {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(meeting.utterances.enumerated()), id: \.element.id) { index, u in
                            let previous = index > 0 ? meeting.utterances[index - 1] : nil
                            let continues = previous?.speaker == u.speaker && u.start - (previous?.end ?? 0) < 20
                            Bubble(utterance: u, name: meeting.name(for: u.speaker), showHeader: !continues, live: false)
                        }
                        ForEach([Speaker.them, .me], id: \.self) { speaker in
                            if let u = model.volatile[speaker] {
                                Bubble(utterance: u, name: meeting.name(for: speaker), showHeader: true, live: true)
                                    .id("live-\(speaker.rawValue)")
                            }
                        }
                        if meeting.utterances.isEmpty && model.volatile.isEmpty {
                            Text(model.isRecording ? "Listening… start talking." : "Nothing was transcribed.")
                                .font(Theme.mono(12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
    }
}

struct Bubble: View {
    let utterance: Utterance
    let name: String
    let showHeader: Bool
    let live: Bool

    private var mine: Bool { utterance.speaker == .me }

    var body: some View {
        HStack(alignment: .top) {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if showHeader {
                    HStack(spacing: 6) {
                        if live { Text("$").foregroundStyle(Theme.orange) }
                        Text(name.uppercased())
                        Text(Clock.format(utterance.start)).foregroundStyle(.tertiary)
                    }
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
                Text(utterance.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(live ? .secondary : .primary)
                    .italic(live)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(mine ? Theme.orange.opacity(0.12) : Color.primary.opacity(0.05))
                    .overlay(
                        Rectangle().strokeBorder(
                            mine ? Theme.orange.opacity(live ? 0.25 : 0.45) : Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: 1, dash: live ? [3, 3] : [])
                        )
                    )
            }
            if !mine { Spacer(minLength: 80) }
        }
    }
}
