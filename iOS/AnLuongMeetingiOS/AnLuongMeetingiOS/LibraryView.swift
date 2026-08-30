import SwiftUI
import AnLuongMeetingCore

@MainActor
final class IOSLibraryViewModel: ObservableObject {
    @Published private(set) var records: [MeetingRecord] = []
    @Published var searchText = ""
    @Published var filter: MeetingFilter = .all
    @Published var errorMessage: String?
    let storage: any MeetingStorage

    init(storage: any MeetingStorage = IOSMeetingStorage()) { self.storage = storage }

    func reload(processingURL: URL? = nil) {
        do {
            let all = try storage.scan(processingURL: processingURL)
            records = MeetingLibraryIndex.filtered(all, searchText: searchText, filter: filter)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ record: MeetingRecord, to name: String) {
        do { try storage.rename(record, to: name); reload() } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ record: MeetingRecord) {
        do { try storage.permanentlyDelete(record); reload() } catch { errorMessage = error.localizedDescription }
    }
}

struct LibraryView: View {
    @ObservedObject var pending: IOSPendingWorkCoordinator
    @StateObject private var model = IOSLibraryViewModel()
    @State private var pendingMemoryCount = 0

    private var hasSearchOrFilter: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.filter != .all
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryHeader
                if pending.shouldShowStatusCard {
                    IOSProcessingStatusCard(pending: pending)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                ZStack {
                    List {
                        NavigationLink {
                            GlossaryView(pending: pending)
                        } label: {
                            GlossaryRow(pendingCount: pendingMemoryCount)
                        }
                        ForEach(model.records) { record in
                            NavigationLink(value: record.id) {
                                MeetingRow(record: record)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    if model.records.isEmpty {
                        ContentUnavailableView(
                            hasSearchOrFilter ? "No matching meetings" : "No meetings yet",
                            systemImage: hasSearchOrFilter ? "magnifyingglass" : "waveform",
                            description: Text(hasSearchOrFilter ? "Try another search term or filter." : "Record your first meeting from the Record tab.")
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .searchable(text: $model.searchText, prompt: "Search meetings")
            .onChange(of: model.searchText) { _, _ in reload() }
            .refreshable { reload() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
            .navigationDestination(for: MeetingRecord.ID.self) { meetingID in
                if let meeting = model.records.first(where: { $0.id == meetingID }) {
                    IOSMeetingDetailView(meeting: meeting, model: model, pending: pending)
                } else {
                    ContentUnavailableView("Meeting unavailable", systemImage: "doc.text", description: Text("This meeting is no longer in the Library."))
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: pending.lastCompletedURL) { _, _ in reload() }
        .onChange(of: pending.activeRecordingURL) { _, _ in reload() }
        .onChange(of: pending.processingState) { _, _ in reload() }
        .onChange(of: pending.pendingURLs) { _, _ in reload() }
    }

    private func reload() {
        model.reload(processingURL: pending.activeRecordingURL)
        pendingMemoryCount = MemoryStore(directory: IOSMeetingStorage().recordingsDirectory).load().pendingCount
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library")
                .font(.largeTitle.weight(.bold))
            Text("Your meetings, in context")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(MeetingFilter.allCases) { filter in
                Button(filter.title) { model.filter = filter; reload() }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            .accessibilityLabel("Filter meetings")
    }
}

private struct GlossaryRow: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Glossary")
                .font(.headline)
            Spacer()
            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.status == .processing ? "arrow.triangle.2.circlepath" : "waveform")
                .font(.title3)
                .foregroundStyle(record.status == .processing ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName).font(.headline).lineLimit(1)
                Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor)
                Text(duration(record.duration)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch record.status {
        case .ready: return .green
        case .partial: return .orange
        case .processing: return .blue
        }
    }

    private func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}
