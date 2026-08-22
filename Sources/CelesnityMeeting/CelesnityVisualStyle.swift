import SwiftUI

enum CelesnityPalette {
    static let graphite = Color(red: 0.098, green: 0.098, blue: 0.098)
    static let graphiteRaised = Color(red: 0.145, green: 0.145, blue: 0.141)
    static let graphiteSoft = Color(red: 0.205, green: 0.205, blue: 0.198)
    static let ivory = Color(red: 0.910, green: 0.894, blue: 0.855)
    static let ivoryBright = Color(red: 0.965, green: 0.953, blue: 0.925)
    static let readingSurface = Color(red: 0.961, green: 0.945, blue: 0.910)
    static let sage = Color(red: 0.839, green: 0.871, blue: 0.816)
    static let sageDark = Color(red: 0.190, green: 0.270, blue: 0.220)
    static let clay = Color(red: 0.878, green: 0.780, blue: 0.690)
    static let clayDark = Color(red: 0.340, green: 0.245, blue: 0.205)
    static let mistBlue = Color(red: 0.780, green: 0.831, blue: 0.875)
    static let mistBlueDark = Color(red: 0.180, green: 0.255, blue: 0.330)
    static let mutedInk = Color(red: 0.365, green: 0.345, blue: 0.315)
    static let mutedIvory = Color(red: 0.690, green: 0.675, blue: 0.640)
}

enum CelesnityTheme {
    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? CelesnityPalette.graphite : CelesnityPalette.ivory
    }

    static func primary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? CelesnityPalette.ivoryBright : CelesnityPalette.graphite
    }

    static func secondary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? CelesnityPalette.mutedIvory : CelesnityPalette.mutedInk
    }

    static func controlSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? CelesnityPalette.graphiteRaised : CelesnityPalette.readingSurface
    }

    static func rowSurface(for colorScheme: ColorScheme, isHovering: Bool) -> Color {
        if colorScheme == .dark {
            return isHovering ? CelesnityPalette.graphiteSoft : CelesnityPalette.graphiteRaised
        }
        return isHovering ? Color.white.opacity(0.42) : Color.white.opacity(0.18)
    }
}

enum CelesnityTypography {
    static func display(_ size: CGFloat) -> Font {
        .custom("Satoshi", size: size)
            .weight(.bold)
    }

    static func body(_ size: CGFloat = 13) -> Font {
        .custom("Satoshi", size: size)
    }

    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced)
    }
}

struct CelesnityStatusStyle {
    let title: String
    let icon: String
    let foreground: Color
    let background: Color
    let darkForeground: Color
    let darkBackground: Color

    static func style(for status: MeetingStatus) -> CelesnityStatusStyle {
        switch status {
        case .ready:
            return CelesnityStatusStyle(
                title: "Ready",
                icon: "checkmark.circle.fill",
                foreground: CelesnityPalette.graphite,
                background: CelesnityPalette.sage,
                darkForeground: CelesnityPalette.ivoryBright,
                darkBackground: CelesnityPalette.sageDark
            )
        case .partial:
            return CelesnityStatusStyle(
                title: "Partial",
                icon: "exclamationmark.circle",
                foreground: CelesnityPalette.graphite,
                background: CelesnityPalette.clay,
                darkForeground: CelesnityPalette.ivoryBright,
                darkBackground: CelesnityPalette.clayDark
            )
        case .processing:
            return CelesnityStatusStyle(
                title: "Processing",
                icon: "arrow.triangle.2.circlepath",
                foreground: CelesnityPalette.graphite,
                background: CelesnityPalette.mistBlue,
                darkForeground: CelesnityPalette.ivoryBright,
                darkBackground: CelesnityPalette.mistBlueDark
            )
        }
    }
}

struct CelesnitySurface<Content: View>: View {
    let fill: Color
    let padding: CGFloat
    let content: Content

    init(
        fill: Color = CelesnityPalette.readingSurface,
        padding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.fill = fill
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CelesnityStatusChip: View {
    let status: MeetingStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = CelesnityStatusStyle.style(for: status)
        Label(style.title, systemImage: style.icon)
            .font(CelesnityTypography.body(11).weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? style.darkForeground : style.foreground)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                colorScheme == .dark ? style.darkBackground : style.background,
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(style.title)")
    }
}

struct CelesnityStatusTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let fill: Color
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: icon)
                        .font(.headline)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                }
                .foregroundStyle(ink.opacity(0.86))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(CelesnityTypography.body(12).weight(.semibold))
                        .foregroundStyle(ink)
                    Text(subtitle)
                        .font(CelesnityTypography.body(11))
                        .foregroundStyle(ink.opacity(0.76))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(13)
            .background(fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        isSelected
                            ? (colorScheme == .dark
                                ? CelesnityPalette.ivoryBright.opacity(0.74)
                                : CelesnityPalette.graphite.opacity(0.8))
                            : .clear,
                        lineWidth: 1.2
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var ink: Color {
        colorScheme == .dark ? CelesnityPalette.ivoryBright : CelesnityPalette.graphite
    }
}

enum CelesnityMotion {
    static let standard = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let gentle = Animation.easeOut(duration: 0.24)
}
