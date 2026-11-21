import SwiftUI

/// Shared look: brand colors, glass surfaces, cards and small controls.
enum Theme {
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.62)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let yellow = Color(red: 1.0, green: 0.85, blue: 0.3)
    static let blue = Color(red: 0.35, green: 0.62, blue: 1.0)

    static let brandGradient = LinearGradient(colors: [pink, orange, yellow], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Surfaces

extension View {
    /// Frosted glass with a hairline edge, for panels and bars floating over the camera.
    func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        background {
            ZStack {
                // Shadow on the shape only, so text and controls inside stay crisp.
                shape.fill(.black.opacity(0.25)).shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                shape.fill(.ultraThinMaterial)
                shape.fill((tint ?? .clear).opacity(0.18))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder func keyboardShortcut(number: Int?) -> some View {
        if let number, number >= 1, number <= 9 {
            keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        } else {
            self
        }
    }
}

/// The "Camera picture" setting: off hides the camera picture everywhere (menu, setup and games),
/// for privacy or a calmer screen. Tracking keeps working; only the picture is hidden.
enum CameraPicture {
    static let key = "showCameraPicture"

    /// Stands in for the camera picture: a deep, playful gradient with soft brand glows.
    struct Hidden: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.38), Color(red: 0.07, green: 0.09, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.pink.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Theme.blue.opacity(0.35), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 760)
            }
        }
    }
}

/// Dimmed live camera with soft brand glows: the player can still see themselves behind the menu.
struct MenuBackground: View {
    let camera: CameraManager

    var body: some View {
        ZStack {
            CameraBackground(session: camera.session)
            LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.5), .black.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.pink.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Theme.blue.opacity(0.28), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 820)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// Gentle press-in for big tappable things.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Round icon button for the control bar, with a hover highlight.
struct BarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Menu pieces

struct GameCard: View {
    let game: GameEntry
    let number: Int?
    let onPlay: () -> Void
    let onExport: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                Text(game.emoji)
                    .font(.system(size: 78))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
                    .scaleEffect(hovering ? 1.08 : 1)
                    .rotationEffect(.degrees(hovering ? -4 : 0))
                Text(game.title)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 214)
            .background(cardShape.fill(game.color.gradient)
                .shadow(color: game.color.opacity(hovering ? 0.65 : 0.35), radius: hovering ? 28 : 16, y: hovering ? 14 : 8))
            .overlay(cardShape.fill(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                                   startPoint: .top, endPoint: .center)))
            .overlay(cardShape.strokeBorder(.white.opacity(hovering ? 0.55 : 0.22), lineWidth: hovering ? 2 : 1))
            .overlay(alignment: .topLeading) { numberBadge }
            .overlay(alignment: .topTrailing) { packBadge }
            .scaleEffect(hovering ? 1.035 : 1)
            .contentShape(cardShape)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(number: number)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help(game.pack?.manifest.description ?? "Play \(game.title)")
        .contextMenu {
            if game.isBuiltIn {
                Text("Built-in game")
            } else {
                Button("Export…", action: onExport)
                Button("Remove", role: .destructive, action: onRemove)
                if let author = game.pack?.manifest.author { Text("By \(author)") }
            }
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 30, style: .continuous) }

    @ViewBuilder private var numberBadge: some View {
        if let number, number <= 9 {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.22)))
                .padding(12)
        }
    }

    @ViewBuilder private var packBadge: some View {
        if !game.isBuiltIn {
            Text("PACK")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.22)))
                .padding(13)
        }
    }
}

/// The last card in the grid: add a game pack.
struct AddGameCard: View {
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                if busy {
                    ProgressView().controlSize(.large)
                    Text("Adding…").font(.system(size: 20, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 34, weight: .bold))
                        .frame(width: 70, height: 70)
                        .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.1)))
                    Text("Add a game").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(".jigglegame file").font(.callout).foregroundStyle(.white.opacity(0.55))
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .frame(height: 214)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.5 : 0.28), style: StrokeStyle(lineWidth: 2, dash: [9, 7])))
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Add a game pack (.jigglegame)")
    }
}

/// "● 1 player ready" style pill.
struct StatusPill: View {
    enum Kind { case good, waiting, warning }
    let kind: Kind
    let text: String
    @State private var pulse = false

    private var color: Color {
        switch kind {
        case .good: return .green
        case .waiting: return Theme.yellow
        case .warning: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.25 : 0.7).opacity(pulse ? 0 : 1)
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .glass(Capsule())
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A one-line notice above the control bar.
struct NoticeBanner: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.white.opacity(0.92))
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glass(Capsule(), tint: tint)
    }
}
