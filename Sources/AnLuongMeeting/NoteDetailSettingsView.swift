import SwiftUI

/// Hallmark · component: settings screen · genre: editorial (AnLuong native design system)
/// states: default · hover (tiles/rows) · focus (text field) · selected (level tile) · disabled (n/a)
/// Pre-flight: reused AnLuongPalette/AnLuongTheme/AnLuongTypography/AnLuongMotion, AnLuongStatusTile,
/// and the tab-underline / capsule-accent voice already established in LibraryView + MeetingDetailView.
/// No stock Form/Picker/Toggle chrome — this screen now speaks the same language as the rest of the app.
struct NoteDetailSettingsView: View {
    @State private var preferences = NoteDetailPreferences.loadSaved()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let defaults = NoteDetailPreferences()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                levelSection
                keepSection
                instructionsSection
                previewSection
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AnLuongTheme.canvas(for: colorScheme))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note Detail")
                    .font(AnLuongTypography.display(28))
                    .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                Text("How much substance future meeting notes keep.")
                    .font(AnLuongTypography.body(12))
                    .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            }
            Spacer()
            if preferences != Self.defaults {
                Button("Reset") { reset() }
                    .buttonStyle(.plain)
                    .font(AnLuongTypography.body(12).weight(.semibold))
                    .foregroundStyle(AnLuongPalette.clayDark)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Detail level

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Detail level")
            HStack(spacing: 12) {
                AnLuongStatusTile(
                    title: "Concise",
                    subtitle: "Compressed summary, quick to skim.",
                    icon: "list.bullet",
                    fill: colorScheme == .dark ? AnLuongPalette.mistBlueDark : AnLuongPalette.mistBlue,
                    isSelected: preferences.level == .concise,
                    action: { setLevel(.concise) }
                )
                AnLuongStatusTile(
                    title: "Detailed",
                    subtitle: "Keeps more substance, less compression.",
                    icon: "text.append",
                    fill: colorScheme == .dark ? AnLuongPalette.clayDark : AnLuongPalette.clay,
                    isSelected: preferences.level == .detailed,
                    action: { setLevel(.detailed) }
                )
            }
        }
    }

    // MARK: - What to keep

    private var keepSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("What to keep")
            AnLuongSurface(fill: AnLuongTheme.controlSurface(for: colorScheme), padding: 4) {
                VStack(spacing: 0) {
                    toggleRow(
                        icon: "quote.opening",
                        title: "Direct quotes",
                        subtitle: "Cite key statements verbatim, with the speaker named when clear.",
                        isOn: $preferences.includeQuotes
                    )
                    rowDivider
                    toggleRow(
                        icon: "number",
                        title: "Technical & numeric details",
                        subtitle: "Keep exact figures, protocols, and tool or device names.",
                        isOn: $preferences.includeTechnicalDetails
                    )
                    rowDivider
                    toggleRow(
                        icon: "point.3.filled.connected.trianglepath.dotted",
                        title: "Minor & tangential points",
                        subtitle: "Don't drop side discussions or small asides.",
                        isOn: $preferences.includeMinorPoints
                    )
                }
            }
        }
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                persist()
            }
        )) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AnLuongPalette.clayDark)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AnLuongTypography.body(13).weight(.semibold))
                        .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                    Text(subtitle)
                        .font(AnLuongTypography.body(11))
                        .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(AnLuongToggleStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AnLuongTheme.secondary(for: colorScheme).opacity(0.14))
            .frame(height: 1)
            .padding(.leading, 44)
    }

    // MARK: - Additional instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Additional instructions")
            AnLuongSurface(fill: AnLuongTheme.controlSurface(for: colorScheme), padding: 4) {
                ZStack(alignment: .topLeading) {
                    if preferences.extraInstructions.isEmpty {
                        Text("e.g. \u{201C}Always list amounts in USD\u{201D} or \u{201C}keep the exact project codenames\u{201D}.")
                            .font(AnLuongTypography.body(12))
                            .foregroundStyle(AnLuongTheme.secondary(for: colorScheme).opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(
                        get: { preferences.extraInstructions },
                        set: { preferences.extraInstructions = $0; persist() }
                    ))
                    .font(AnLuongTypography.body(12))
                    .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 84)
                }
            }
            Text("Followed for every future note and every \u{201C}Regenerate Note.\u{201D}")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        }
    }

    // MARK: - Prompt preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Prompt preview")
            AnLuongSurface(fill: AnLuongTheme.controlSurface(for: colorScheme)) {
                Group {
                    if preferences.promptAddendum.isEmpty {
                        Text("No additions — notes generate in the original concise format.")
                            .font(AnLuongTypography.body(12))
                            .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
                    } else {
                        Text(preferences.promptAddendum.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(AnLuongTypography.mono(11))
                            .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : AnLuongMotion.gentle, value: preferences.promptAddendum)
            }
            Text("Exactly what gets appended before the transcript.")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        }
    }

    // MARK: - Shared

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AnLuongTypography.body(11).weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            .textCase(.uppercase)
    }

    private func setLevel(_ level: NoteDetailLevel) {
        withAnimation(reduceMotion ? nil : AnLuongMotion.standard) {
            preferences.level = level
        }
        persist()
    }

    private func reset() {
        withAnimation(reduceMotion ? nil : AnLuongMotion.gentle) {
            preferences = Self.defaults
        }
        persist()
    }

    private func persist() {
        preferences.save()
    }
}
