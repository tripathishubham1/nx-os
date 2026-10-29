// The OS pages: Home (Home.swift), Store (Store.swift), Games, Builds, Stats and System (Panels.swift), Library (cover flow), Games, Builds, Stats and System.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What every page can ask the shell to do.
struct Actions {
    var play: (Game) -> Void = { _ in }
    var open: (Game) -> Void = { _ in }        // show it in the Library page
    var options: (Game) -> Void = { _ in }     // the per-game settings panel
    var reveal: (Game) -> Void = { _ in }
    var log: (Game) -> Void = { _ in }
    var go: (Page) -> Void = { _ in }
    var store: (StoreGame) -> Void = { _ in }   // a game's page in the Store
    var search: () -> Void = {}
    var delete: (Game) -> Void = { _ in }
}

enum Page: Int, CaseIterable, Identifiable {
    case home, store, library, games, builds, stats, system
    var id: Int { rawValue }
    var title: String { ["Home", "Store", "Library", "Games", "Builds", "Stats", "System"][rawValue] }
    var icon: String { ["house.fill", "bag.fill", "rectangle.stack.fill", "square.grid.2x2.fill", "hammer.fill", "chart.bar.fill", "gearshape.fill"][rawValue] }
    var outlineIcon: String { ["house", "bag", "rectangle.stack", "square.grid.2x2", "hammer", "chart.bar", "gearshape"][rawValue] }
    static let tabs: [Page] = [.home, .store, .library, .games, .builds, .stats, .system]
    /// Pages where ← → move a selection, and A / Y act on it.
    var browses: Bool { [.home, .store, .library, .games].contains(self) }
}

// MARK: - Shared pieces

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.ui(24, .heavy)).tracking(-0.5).foregroundStyle(.white)
            if let subtitle { Text(subtitle).font(.ui(13, .medium)).foregroundStyle(.white.opacity(0.6)) }
        }
    }
}

struct Chip: View {
    let label: String
    let selected: Bool
    var icon: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon ?? Catalog.icon(label)).font(.ui(14, .semibold))
                Text(label).font(.ui(14, .semibold))
            }
            .foregroundStyle(selected ? mint : hover ? .white : Theme.ink2)
            .padding(.horizontal, 18).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? mint.opacity(0.14) : Theme.card.opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? mint.opacity(0.55) : .white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct ChipRow: View {
    let chips: [String]
    @Binding var selected: String
    var body: some View {
        ArrowScroller {
            HStack(spacing: 12) {
                ForEach(chips, id: \.self) { c in
                    Chip(label: c, selected: c == selected) {
                        Sfx.move(); withAnimation(spring) { selected = c }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
                Text(title)
            }
            .font(.ui(13, .bold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(Capsule().fill(prominent ? AnyShapeStyle(tint.opacity(hover ? 1 : 0.92)) : AnyShapeStyle(Color.white.opacity(hover ? 0.18 : 0.1))))
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : hover ? 0.3 : 0.14), lineWidth: 1))
            .shadow(color: .black.opacity(prominent ? (hover ? 0.3 : 0.18) : 0), radius: hover ? 8 : 5, y: 3)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
    }
}

/// Buttons sink a little while pressed and spring back.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A round glass button holding one symbol.
struct IconButton: View {
    let icon: String
    var help = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.black.opacity(hover ? 0.6 : 0.4)))
                .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.35 : 0.15), lineWidth: 1))
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(PressStyle()).help(help)
        .accessibilityLabel(help.isEmpty ? icon : help)
        .onHover { h in withAnimation(snappy) { hover = h } }
    }
}

/// The scroll state of one horizontal row, shared by the row and the arrows that move it.
final class HScrollModel: ObservableObject {
    @Published var position = ScrollPosition()
    @Published var offset: CGFloat = 0
    @Published var contentWidth: CGFloat = 0
    @Published var width: CGFloat = 0
    var canBack: Bool { offset > 4 }
    var canForward: Bool { offset < contentWidth - width - 4 }
    var scrollable: Bool { contentWidth > width + 4 }

    /// Moves the row by most of its width.
    func scroll(_ d: CGFloat) {
        let x = min(max(0, offset + d * width * 0.8), max(0, contentWidth - width))
        withAnimation(.smooth(duration: reduceMotion ? 0.01 : 0.45)) { position.scrollTo(x: x) }
    }
}

/// A horizontal row. Given a `model`, its arrows live elsewhere (an `ArrowPair` in the section
/// heading); without one, small arrows sit on a fade at its edges.
struct ArrowScroller<Content: View>: View {
    var model: HScrollModel? = nil
    @ViewBuilder var content: Content
    @StateObject private var own = HScrollModel()

    var body: some View {
        let m = model ?? own
        ScrollView(.horizontal, showsIndicators: false) { content }
            .scrollPosition(Binding(get: { m.position }, set: { m.position = $0 }))
            .onScrollGeometryChange(for: [CGFloat].self) { g in [g.contentOffset.x, g.contentSize.width, g.containerSize.width] } action: { _, v in
                if m.offset != v[0] { m.offset = v[0] }
                if m.contentWidth != v[1] { m.contentWidth = v[1] }
                if m.width != v[2] { m.width = v[2] }
            }
            .overlay(alignment: .leading) { if model == nil && own.canBack { edge(left: true) } }
            .overlay(alignment: .trailing) { if model == nil && own.canForward { edge(left: false) } }
            .animation(.easeOut(duration: 0.2), value: own.canBack)
            .animation(.easeOut(duration: 0.2), value: own.canForward)
    }

    /// An edge arrow on a fade of the page colour, so it never sits on top of an item.
    private func edge(left: Bool) -> some View {
        ZStack(alignment: left ? .leading : .trailing) {
            LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0)], startPoint: left ? .leading : .trailing, endPoint: left ? .trailing : .leading)
                .frame(width: 72).allowsHitTesting(false)
            ArrowButton(left: left, small: true) { own.scroll(left ? -1 : 1) }.padding(left ? .leading : .trailing, 12)
        }
        .transition(.opacity)
    }
}

/// ‹ › for a row, at the end of its section heading: dimmed at either end, hidden when the row fits.
struct ArrowPair: View {
    @ObservedObject var model: HScrollModel
    var body: some View {
        if model.scrollable {
            HStack(spacing: 8) {
                ArrowButton(left: true, small: true) { model.scroll(-1) }.disabled(!model.canBack).opacity(model.canBack ? 1 : 0.35)
                ArrowButton(left: false, small: true) { model.scroll(1) }.disabled(!model.canForward).opacity(model.canForward ? 1 : 0.35)
            }
            .transition(.opacity)
        }
    }
}

/// A titled horizontal row: its heading, the ‹ › pair at the heading's end, then the row.
struct ScrollSection<Header: View, Content: View>: View {
    var spacing: CGFloat = 12
    var bleed: CGFloat = 0          // the row reaches this far past the heading's edges, for shadows
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @StateObject private var model = HScrollModel()
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 12) {
                header
                Spacer(minLength: 12)
                ArrowPair(model: model)
            }
            ArrowScroller(model: model) { content }.padding(.horizontal, -bleed)
        }
    }
}

struct ArrowButton: View {
    let left: Bool
    var small = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: left ? "chevron.left" : "chevron.right").font(.system(size: small ? 12 : 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: small ? 32 : 38, height: small ? 32 : 38)
                .background(Circle().fill(Theme.rail.mix(with: .white, by: hover ? 0.12 : 0.04)))
                .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.3 : 0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                .scaleEffect(hover ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
        .help(left ? "Scroll back" : "Scroll forward")
        .accessibilityLabel(left ? "Scroll back" : "Scroll forward")
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(20)
    }
}

struct ProgressBar: View {
    let value: Double
    var tint: Color = .orange
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

func metaText(_ g: Game, playTime: [String: Double], failed: [String: String] = [:]) -> String {
    if let why = failed[g.id], g.state == .ready { return why }
    if g.state == .building {
        return g.build.map { "Building · \(Int($0.overall * 100))%" } ?? "Building"
    }
    let t = playTime[g.id] ?? 0
    return (t > 0 ? formatPlayTime(t) : "New") + (g.version.isEmpty ? "" : "  |  v\(g.version)")
}

// MARK: - Posters (Games page; the Home page is in Home.swift)

struct PosterCard: View {
    let game: Game
    let width: CGFloat
    let meta: String
    let selected: Bool
    let running: Bool
    let actions: Actions
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            poster
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: game.state == .building ? "hammer.fill" : "star.fill")
                        .font(.system(size: 10)).foregroundStyle(game.state == .building ? .orange : .yellow)
                    Text(meta).font(.ui(12, .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
        }
        .frame(width: width)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { hover = h } }
    }

    private var poster: some View {
        let h = width * 1.32
        return ZStack {
            Group {
                if let icon = game.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: width, height: h).clipped()
                } else {
                    BuildingFace(size: width, status: game.build).frame(width: width, height: h)
                        .background(Color(white: 0.08))
                }
            }
            LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center).blendMode(.screen)
            if hover && game.state == .ready && !running {
                Button { actions.play(game) } label: {
                    Image(systemName: "play.fill").font(.ui(20, .bold)).foregroundStyle(.black)
                        .frame(width: 54, height: 54).background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                .buttonStyle(.plain).transition(.scale.combined(with: .opacity))
            }
            if running {
                Text("RUNNING").font(.ui(11, .heavy)).tracking(1.2).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(.green))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(selected ? AnyShapeStyle(game.accent) : AnyShapeStyle(Color.white.opacity(hover ? 0.4 : 0.1)), lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(hover || selected ? 0.4 : 0.28), radius: hover ? 14 : 9, y: hover ? 9 : 6)
        .offset(y: hover ? -6 : 0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if game.state == .ready { actions.play(game) } }
        .onTapGesture { actions.open(game) }
        .tappable(game.name + (running ? ", running" : game.state == .building ? ", building" : ""), hint: "Opens it in the Library") { actions.open(game) }
        .accessibilityAction(named: "Play") { if game.state == .ready { actions.play(game) } }
        .contextMenu {
            if game.state == .ready {
                Button("Play") { actions.play(game) }
                Button("Settings…") { actions.options(game) }
            }
            Button("Show in Library") { actions.open(game) }
            Button("Show in Finder") { actions.reveal(game) }
            Divider()
            Button("Delete Game…", role: .destructive) { actions.delete(game) }
        }
    }
}

struct PosterRow: View {
    let games: [Game]
    let playTime: [String: Double]
    let running: Set<String>
    let selectedID: String?
    let actions: Actions
    var body: some View {
        ScrollViewReader { proxy in
            ArrowScroller {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(games) { g in
                        PosterCard(game: g, width: 152, meta: metaText(g, playTime: playTime), selected: g.id == selectedID,
                                   running: running.contains(g.id), actions: actions)
                            .id(g.id)
                    }
                }
                .padding(.vertical, 16).padding(.horizontal, 4)
            }
            .onChange(of: selectedID) { _, id in if let id { withAnimation(spring) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }
}

// MARK: - Library (cover flow)

struct LibraryPage: View {
    let games: [Game]
    let library: Library
    @Binding var selectedID: String?
    let actions: Actions
    @State private var dragOffset: CGFloat = 0

    private var index: Int { games.firstIndex { $0.id == selectedID } ?? 0 }
    private var current: Game? { games.indices.contains(index) ? games[index] : nil }

    var body: some View {
        GeometryReader { geo in
            // the details block below needs about 250 pt, so the cover gets what's left
            let card = max(140, min(geo.size.height * 0.46, geo.size.width * 0.26, (geo.size.height - 250) / 1.38))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                carousel(card: card, spacing: card * 0.5, width: geo.size.width).frame(height: card * 1.38)
                    .overlay {
                        HStack {
                            if index > 0 { ArrowButton(left: true) { step(-1) } }
                            Spacer()
                            if index < games.count - 1 { ArrowButton(left: false) { step(1) } }
                        }
                        .padding(.horizontal, 8)
                    }
                dots.padding(.top, 2)
                details.padding(.top, 22)
                Spacer(minLength: 0)
            }
        }
    }

    private func step(_ d: Int) {
        let next = max(0, min(games.count - 1, index + d))
        guard next != index else { return }
        Sfx.move()
        withAnimation(spring) { selectedID = games[next].id }
    }

    private func carousel(card: CGFloat, spacing: CGFloat, width: CGFloat) -> some View {
        let drag = dragOffset / spacing
        return ZStack {
            ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                CarouselItem(game: g, isRunning: library.running.contains(g.id), offset: CGFloat(i - index) + drag,
                             isCenter: i == index && dragOffset == 0, isLaunching: library.launching == g.id,
                             card: card, spacing: spacing)
                    .onTapGesture {
                        if i == index { if g.state == .ready { actions.play(g) } }
                        else { Sfx.move(); withAnimation(spring) { selectedID = g.id } }
                    }
                    .tappable(g.name, hint: i == index ? "Plays it" : "Selects it") {
                        if i == index { if g.state == .ready { actions.play(g) } } else { selectedID = g.id }
                    }
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .onChanged { dragOffset = $0.translation.width }
            .onEnded { v in
                let steps = Int((-v.predictedEndTranslation.width / spacing).rounded())
                if steps != 0 { Sfx.move() }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    let i = max(0, min(games.count - 1, index + steps))
                    if games.indices.contains(i) { selectedID = games[i].id }
                    dragOffset = 0
                }
            })
        .animation(spring, value: index)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(games.indices, id: \.self) { i in
                Capsule().fill(i == index ? Color.white : Color.white.opacity(0.25)).frame(width: i == index ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35), value: index)
    }

    @ViewBuilder private var details: some View {
        if let g = current {
            VStack(spacing: 12) {
                Text(g.name).font(.ui(38, .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    ForEach(Catalog.genres(of: g), id: \.self) { c in
                        Label(c, systemImage: Catalog.icon(c)).font(.ui(11, .semibold))
                            .foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(libraryMeta(g)).font(.ui(13, .medium)).foregroundStyle(.white.opacity(0.6))
                actionRow(g).padding(.top, 4)
            }
            .padding(.horizontal, 40)
            .animation(.easeOut(duration: 0.3), value: g.id)
        }
    }

    private func libraryMeta(_ g: Game) -> String {
        var parts: [String] = []
        if let b = g.build, g.state == .building {
            parts.append("Step \(b.k) of \(b.n): \(b.stage)" + (b.percent.map { " \($0)%" } ?? ""))
            if let eta = b.eta { parts.append("about \(eta) left in this step") }
        }
        if !g.version.isEmpty { parts.append("Version \(g.version)") }
        if let t = library.playTime[g.id], t > 0 { parts.append("\(formatPlayTime(t)) played") }
        if let d = library.lastPlayed[g.id] { parts.append("Last played " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())) }
        else if g.state == .ready { parts.append("Never played") }
        return parts.joined(separator: "   ·   ")
    }

    private func actionRow(_ g: Game) -> some View {
        let ready = g.state == .ready
        let running = library.running.contains(g.id)
        return HStack(spacing: 14) {
            Button { actions.play(g) } label: {
                HStack(spacing: 10) {
                    Image(systemName: running ? "dot.radiowaves.left.and.right" : "play.fill")
                    Text(running ? "Running" : ready ? "Play" : "Building")
                }
                .font(.ui(17, .heavy))
                .foregroundStyle(ready && !running ? Color.black : Color.white.opacity(0.7))
                .padding(.horizontal, 46).padding(.vertical, 15)
                .background(Capsule().fill(ready && !running ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12))))
                .shadow(color: .black.opacity(ready && !running ? 0.3 : 0), radius: 10, y: 5)
            }
            .buttonStyle(.plain).disabled(!ready || running)
            round("slider.horizontal.3", "Settings") { actions.options(g) }.disabled(!ready).opacity(ready ? 1 : 0.4)
            round("folder.fill", "Show in Finder") { actions.reveal(g) }
            round("doc.text.fill", "Open the log") { actions.log(g) }
            round("trash.fill", "Delete game") { actions.delete(g) }.disabled(running || g.state != .ready)
        }
    }

    private func round(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(17, .semibold)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 52, height: 52).modifier(GlassMod())
        }
        .buttonStyle(PressStyle()).help(help).accessibilityLabel(help)
    }
}

/// Images bundled in the app's Resources (Avatars, Art), with the source tree as a fallback when run from build/.
enum Bundled {
    private static var cache: [String: NSImage] = [:]
    static func image(_ folder: String, _ name: String) -> NSImage? {
        let key = "\(folder)/\(name)"
        if let hit = cache[key] { return hit }
        let roots = [Bundle.main.resourceURL,
                     URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../../../Resources")]
        let img = roots.compactMap { $0 }.lazy.compactMap { NSImage(contentsOf: $0.appendingPathComponent(key)) }.first
        cache[key] = img
        return img
    }
    static func names(_ folder: String) -> [String] {
        let roots = [Bundle.main.resourceURL,
                     URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../../../Resources")]
        for r in roots.compactMap({ $0 }) {
            let list = ((try? FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent(folder).path)) ?? [])
                .filter { $0.hasSuffix(".png") }.sorted()
            if !list.isEmpty { return list }
        }
        return []
    }
}

/// The player's picture: a chosen avatar, or their initial. `editable` opens the picker on click.
struct Avatar: View {
    var size: CGFloat = 34
    var editable = false
    @AppStorage("avatar") private var avatar = ""
    @State private var picking = false

    var body: some View {
        if editable {
            Button { picking = true } label: { face }
                .buttonStyle(PressStyle())
                .help("Change your avatar")
                .accessibilityLabel("Your avatar. Change it")
                .popover(isPresented: $picking, arrowEdge: .bottom) { AvatarPicker(selected: $avatar) { picking = false } }
        } else {
            face
        }
    }

    private var face: some View {
        ZStack {
            if let img = avatar.isEmpty ? nil : Bundled.image("Avatars", avatar) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.4), Color(red: 0.45, green: 0.3, blue: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(SystemInfo.firstName.prefix(1)).uppercased())
                    .font(.ui(size * 0.45, .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
    }
}

struct AvatarPicker: View {
    @Binding var selected: String
    let done: () -> Void
    private let names = Bundled.names("Avatars")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your avatar").font(.ui(15, .bold)).foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(60), spacing: 12), count: 5), spacing: 12) {
                option("") {
                    Text(String(SystemInfo.firstName.prefix(1)).uppercased()).font(.ui(24, .heavy)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.4), Color(red: 0.45, green: 0.3, blue: 1)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
                ForEach(names, id: \.self) { n in
                    option(n) {
                        if let img = Bundled.image("Avatars", n) {
                            Image(nsImage: img).resizable().frame(width: 56, height: 56).clipShape(Circle())
                        }
                    }
                }
            }
            Text("Avatars by DiceBear").font(.ui(11, .medium)).foregroundStyle(Theme.ink2)
        }
        .padding(18)
        .background(Theme.rail)
        .environment(\.colorScheme, .dark)
    }

    private func option<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        Button { selected = name; done() } label: {
            content()
                .overlay(Circle().strokeBorder(selected == name ? mint : .clear, lineWidth: 3).padding(-4))
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(name.isEmpty ? "Your initial" : "Avatar \(name.split(separator: "-").last.map { String($0.dropLast(4)) } ?? name)")
        .accessibilityAddTraits(selected == name ? .isSelected : [])
    }
}

