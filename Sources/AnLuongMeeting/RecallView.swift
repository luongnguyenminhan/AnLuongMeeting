import SwiftUI

struct RecallView: View {
    @ObservedObject var engine: RecordingEngine
    let meetings: [MeetingRecord]
    let onSelectMeeting: (String) -> Void

    @State private var question = ""
    @State private var isSearching = false
    @State private var answer: RecallAnswer?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            questionField
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching your meetings…")
                        .font(AnLuongTypography.body(12))
                        .foregroundStyle(AnLuongPalette.mutedInk)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(AnLuongTypography.body(12))
                    .foregroundStyle(.red)
            } else if let answer {
                answerView(answer)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AnLuongPalette.readingSurface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recall")
                .font(AnLuongTypography.display(28))
                .foregroundStyle(AnLuongPalette.graphite)
            Text("Ask a question across every meeting you've recorded.")
                .font(AnLuongTypography.body(12))
                .foregroundStyle(AnLuongPalette.mutedInk)
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("What did we decide about…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSearching || apiKeyMissing)
                    .onSubmit(submit)
                Button("Ask", action: submit)
                    .disabled(isSearching || apiKeyMissing || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if apiKeyMissing {
                Text("Enter a Gemini API key before using Recall.")
                    .font(AnLuongTypography.body(11))
                    .foregroundStyle(AnLuongPalette.mutedInk)
            }
        }
    }

    private var apiKeyMissing: Bool {
        engine.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func answerView(_ answer: RecallAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(answer.text)
                .font(AnLuongTypography.body(14))
                .foregroundStyle(AnLuongPalette.graphite)
                .textSelection(.enabled)

            if !answer.citedMeetingIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOURCES")
                        .font(AnLuongTypography.mono(10).weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(AnLuongPalette.mutedInk)
                    ForEach(answer.citedMeetingIDs, id: \.self) { id in
                        if let meeting = meetings.first(where: { $0.id == id }) {
                            Button(meeting.displayName) { onSelectMeeting(id) }
                                .buttonStyle(.plain)
                                .font(AnLuongTypography.body(13).weight(.medium))
                                .foregroundStyle(AnLuongPalette.clay)
                        }
                    }
                }
            }
        }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        errorMessage = nil
        answer = nil
        isSearching = true
        Task {
            do {
                let result = try await engine.answerRecallQuestion(question: trimmed, meetings: meetings)
                await MainActor.run {
                    answer = result
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }
}
