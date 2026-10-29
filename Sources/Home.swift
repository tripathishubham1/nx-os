// The Home page, after the user's reference design: a greeting, "Popular games" cards whose
// characters pop out of their tiles, a row of small Store tiles, a tabbed shelf, and a side panel
// with the player, search, stat tiles, a genre radar and Store news.
// Character art is a transparent PNG per title ID, from Resources/Characters in the app or
// /Volumes/T7/Games/_art; games without one show their icon inside the tile instead.
import SwiftUI
import AppKit

let mint = Color(red: 0.2, green: 0.86, blue: 0.64)

enum CharacterArt {
    private static var cache: [String: NSImage?] = [:]
    private static let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Characters"),
                               URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                                   .appendingPathComponent("../../../../Resources/Characters"),
                               gamesRoot.appendingPathComponent("_art")].compactMap { $0 }

    static func image(for titleID: String) -> NSImage? {
        let tid = titleID.uppercased()
        if let hit = cache[tid] { return hit }
        let img = dirs.lazy.compactMap { NSImage(contentsOf: $0.appendingPathComponent("\(tid).png")) }.first
        if img != nil { cache[tid] = img }      // a miss is checked again, so art added later appears
        return img
    }
}

struct HomePage: View {
    let games: [Game]
    let library: Library
    @ObservedObject var catalog: StoreCatalog
    @ObservedObject var builds: BuildQueue
    let selectedID: String?
    let query: String
    let actions: Actions
    let footer: AnyView
    @State private var tab = "Your games"
    @Namespace private var tabNS
    @StateObject private var popularRow = HScrollModel()
    @StateObject private var freshRow = HScrollModel()
    @StateObject private var trendRow = HScrollModel()

    /// Most played first, then most recent: the order ← → walks through.
    static func popular(_ games: [Game], _ library: Library) -> [Game] {
        games.sorted {
            let a = library.playTime[$0.id] ?? 0, b = library.playTime[$1.id] ?? 0
            if a != b { return a > b }
            return (library.lastPlayed[$0.id] ?? .distantPast) > (library.lastPlayed[$1.id] ?? .distantPast)
        }
    }
    private var popular: [Game] { Self.popular(games, library) }
    private var lastPlayed: Game? {
        games.filter { $0.state == .ready && library.lastPlayed[$0.id] != nil }
            .max { (library.lastPlayed[$0.id] ?? .distantPast) < (library.lastPlayed[$1.id] ?? .distantPast) }
            ?? games.first { $0.state == .ready }
    }

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width > 1180 ? 300.0 : 264.0
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        if query.isEmpty { greeting }
                        popularShelf
                        if query.isEmpty { fresh }
                        trending
                    }
                    .padding(.bottom, 24)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.965), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                footer
                }
                SidePanel(games: games, library: library, catalog: catalog, builds: builds, actions: actions)
                    .frame(width: side)
            }
        }
    }

    // MARK: Greeting

    private var greeting: some View {
        let ready = games.filter { $0.state == .ready }.count
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hello, \(SystemInfo.firstName)").font(.ui(34, .bold)).tracking(-0.6).foregroundStyle(.white)
                Text(ready == 0 ? "Welcome back. Find something to play in the Store."
                     : "Welcome back. \(ready) \(ready == 1 ? "game is" : "games are") ready to play.")
                    .font(.ui(14, .medium)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 12)
            if let g = lastPlayed {
                CTAButton(title: library.lastPlayed[g.id] == nil ? "Play \(g.name)" : "Continue \(g.name)") { actions.play(g) }
                    .frame(maxWidth: 360)
            } else {
                CTAButton(title: "Open the Store", icon: "bag.fill") { actions.go(.store) }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .raised(24)
        .background {
            ZStack {
                if let icon = lastPlayed?.icon {
                    Color.clear.overlay(alignment: .trailing) {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill).frame(width: 460)
                            .blur(radius: 22).opacity(0.3)
                            .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    // MARK: Popular games

    private var popularShelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(query.isEmpty ? "Popular games" : "Your games matching “\(query)”").font(.ui(17, .bold)).foregroundStyle(.white)
                Spacer()
                Button { actions.go(.games) } label: {
                    HStack(spacing: 5) { Text("See all"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .font(.ui(13, .semibold)).foregroundStyle(Theme.ink2)
                }
                .buttonStyle(PressStyle())
                ArrowPair(model: popularRow).padding(.leading, 6)
            }
            if popular.isEmpty {
                Text(query.isEmpty ? "Games you install show up here." : "None of your games match. The Store may have it.")
                    .font(.ui(13, .medium)).foregroundStyle(Theme.ink2).padding(.vertical, 30)
            } else {
                ScrollViewReader { proxy in
                    ArrowScroller(model: popularRow) {
                        LazyHStack(alignment: .bottom, spacing: 24) {
                            ForEach(Array(popular.enumerated()), id: \.element.id) { i, g in
                                PopCard(game: g, selected: g.id == selectedID, index: i,
                                        meta: metaText(g, playTime: library.playTime, failed: library.failedStart),
                                        running: library.running.contains(g.id), warning: library.failedStart[g.id] != nil, actions: actions)
                                    .id(g.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
                    }
                    .padding(.horizontal, -12)
                    .onChange(of: selectedID) { _, id in if let id { withAnimation(spring) { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
    }

    // MARK: Fresh in the Store (the reference's row of small square tiles)

    private var fresh: some View {
        let items = Array(catalog.games.suffix(16).reversed())
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fresh in the Store").font(.ui(17, .bold)).foregroundStyle(.white)
                Spacer()
                ArrowPair(model: freshRow)
            }
            ArrowScroller(model: freshRow) {
                HStack(spacing: 16) {
                    ForEach(items) { g in MiniTile(game: g) { actions.store(g) } }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .padding(.horizontal, -12)
        }
    }

    // MARK: Trending

    private var tabs: [(String, [TrendItem])] {
        let installed = popular.map { g -> TrendItem in
            let shot = catalog.games.first { $0.id == g.titleID.uppercased() }
            let status: (String, Color) = library.running.contains(g.id) ? ("Running", .green)
                : g.state == .building ? ("Building", .orange)
                : library.failedStart[g.id].map { ($0, Color.yellow) } ?? ("Ready", mint)
            return TrendItem(id: g.id, title: g.name, image: shot?.image, icon: g.icon,
                             meta: (library.playTime[g.id] ?? 0) > 0 ? formatPlayTime(library.playTime[g.id] ?? 0) : "Not played yet",
                             metaIcon: "clock", status: status.0, statusColor: status.1) {
                g.state == .building ? actions.go(.builds) : actions.open(g)
            }
        }
        func store(_ list: [StoreGame]) -> [TrendItem] {
            list.prefix(14).map { s in
                TrendItem(id: s.id, title: s.name, image: s.image, icon: nil, meta: s.size ?? "Size unknown", metaIcon: "internaldrive",
                          status: s.note.contains("60 fps") ? "60 fps" : "In Store", statusColor: s.note.contains("60 fps") ? .cyan : Theme.ink2) {
                    actions.store(s)
                }
            }
        }
        return [("Your games", installed),
                ("Runs at 60 fps", store(catalog.games.filter { $0.note.contains("60 fps") })),
                ("Quick to build", store(catalog.games.filter { ($0.sizeGB ?? 99) < 2 }.sorted { ($0.sizeGB ?? 0) < ($1.sizeGB ?? 0) })),
                ("Pokémon", store(catalog.games.filter { $0.name.contains("Pokémon") }))]
    }

    private var trending: some View {
        let all = tabs
        let items = all.first { $0.0 == tab }?.1 ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                ForEach(all, id: \.0) { t in
                    Button { withAnimation(snappy) { tab = t.0 } } label: {
                        VStack(spacing: 7) {
                            Text(t.0).font(.ui(15, tab == t.0 ? .bold : .semibold))
                                .foregroundStyle(tab == t.0 ? .white : Theme.ink2)
                            ZStack {
                                Capsule().fill(.clear).frame(height: 3)
                                if tab == t.0 { Capsule().fill(mint).frame(height: 3).matchedGeometryEffect(id: "u", in: tabNS) }
                            }
                        }
                        .fixedSize().contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(tab == t.0 ? .isSelected : [])
                }
                Spacer(minLength: 0)
                ArrowPair(model: trendRow).padding(.bottom, 8)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).offset(y: -1) }
            if items.isEmpty {
                Text("Nothing here yet.").font(.ui(13, .medium)).foregroundStyle(Theme.ink2).padding(.vertical, 20)
            } else {
                ArrowScroller(model: trendRow) {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in TrendCard(item: item, index: i) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .padding(.horizontal, -12)
                .id(tab)
                .transition(.opacity)
            }
        }
    }
}

/// A small square Store tile with the game's name under it.
struct MiniTile: View {
    let game: StoreGame
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            VStack(spacing: 7) {
                Thumb(url: game.image, max: 240)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(hover ? 0.6 : 0.12), lineWidth: hover ? 2 : 1))
                    .shadow(color: .black.opacity(0.3), radius: hover ? 10 : 4, y: 4)
                    .scaleEffect(hover ? 1.06 : 1)
                Text(game.name).font(.ui(11, .semibold)).foregroundStyle(hover ? .white : Theme.ink2)
                    .lineLimit(1).frame(width: 64)
            }
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
        .help(game.name)
        .accessibilityLabel("\(game.name), in the Store")
    }
}

// MARK: - Pieces

/// The page's one call to action: a bright mint pill.
struct CTAButton: View {
    let title: String
    var icon = "play.fill"
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.ui(14, .bold)).lineLimit(1)
                Image(systemName: icon).font(.system(size: 10, weight: .heavy)).foregroundStyle(mint)
                    .frame(width: 22, height: 22).background(Circle().fill(Color(white: 0.08)))
            }
            .foregroundStyle(Color(white: 0.06))
            .padding(.leading, 20).padding(.trailing, 7).padding(.vertical, 7)
            .background(Capsule().fill(LinearGradient(colors: [mint, Color(red: 0.12, green: 0.72, blue: 0.62)], startPoint: .leading, endPoint: .trailing)))
            .shadow(color: .black.opacity(hover ? 0.3 : 0.2), radius: hover ? 10 : 6, y: hover ? 5 : 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
    }
}

/// A rounded colour tile with the game's character standing in it and breaking out of the top.
struct PopCard: View {
    let game: Game
    let selected: Bool
    let index: Int
    let meta: String
    let running: Bool
    var warning = false
    let actions: Actions
    @State private var hover = false
    @State private var shown = false

    private let tile = CGSize(width: 172, height: 150)
    private var overflow: CGFloat { tile.height * 0.42 }     // how far a character may rise above its tile
    private var lifted: Bool { hover || selected }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                tileShape
                figure
            }
            .frame(width: tile.width, height: tile.height + overflow, alignment: .bottom)
            VStack(spacing: 3) {
                Text(game.name).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1)
                Text(running ? "Running" : game.state == .building ? "Building…" : meta)
                    .font(.ui(12, .medium)).foregroundStyle(running ? .green : warning ? .yellow : .white.opacity(0.6)).lineLimit(1)
            }
            .frame(width: tile.width)
        }
        .offset(y: lifted ? -8 : (shown ? 0 : 20))
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hover = h } }
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
        .onAppear {
            if reduceMotion { shown = true; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78).delay(Double(min(index, 8)) * 0.06)) { shown = true }
        }
    }

    private var tint: Color { game.accent }

    private var tileShape: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.28), tint, tint.mix(with: .black, by: 0.3)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // soft cloud shapes along the bottom
            ZStack {
                Circle().fill(.white.opacity(0.14)).frame(width: 110).offset(x: -52, y: 58)
                Circle().fill(.white.opacity(0.1)).frame(width: 140).offset(x: 30, y: 74)
                Circle().fill(.white.opacity(0.08)).frame(width: 90).offset(x: 78, y: 40)
            }
            .blur(radius: 1)
            .clipShape(shape)
            // light from the top edge
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            if selected { shape.strokeBorder(.white, lineWidth: 3).padding(-6) }
        }
        .frame(width: tile.width, height: tile.height)
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.25), radius: lifted ? 16 : 10, y: lifted ? 10 : 6)
    }

    @ViewBuilder private var figure: some View {
        if let art = CharacterArt.image(for: game.titleID) {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: tile.width, height: tile.height + overflow - 14, alignment: .bottom)
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 10)
                .scaleEffect(lifted ? 1.06 : 1, anchor: .bottom)
                // inside the tile the figure is clipped to its rounded corners; above it, it is free
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle()
                        RoundedRectangle(cornerRadius: 32, style: .continuous).frame(width: tile.width, height: tile.height)
                    }
                }
        } else if let icon = game.icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: tile.width * 0.7, height: tile.width * 0.7)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 10)
                .rotationEffect(.degrees(lifted ? -2 : -6))
                .offset(y: -(tile.height - tile.width * 0.7) / 2 - (lifted ? 34 : 26))
        } else {
            BuildingFace(size: tile.height * 0.8, status: game.build)
                .frame(width: tile.width - 20, height: tile.height - 20)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.bottom, 10)
        }
    }
}

struct TrendItem: Identifiable {
    let id: String
    let title: String
    let image: URL?
    let icon: NSImage?
    let meta: String
    let metaIcon: String
    let status: String
    let statusColor: Color
    let open: () -> Void
}

/// A landscape screenshot card with a title and a stat line.
struct TrendCard: View {
    let item: TrendItem
    let index: Int
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let url = item.image { Thumb(url: url, max: 600) }
                else if let icon = item.icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill) }
                else { Color.white.opacity(0.06) }
            }
            .frame(width: 210, height: 118).clipped()
            .scaleEffect(hover ? 1.05 : 1)
            .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.ui(13, .bold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 10) {
                    Label(item.meta, systemImage: item.metaIcon).labelStyle(.titleAndIcon).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(item.statusColor).frame(width: 7, height: 7)
                        Text(item.status)
                    }
                }
                .font(.ui(11, .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(width: 210, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .raised(16, lit: hover)
        .offset(y: hover ? -4 : 0)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(snappy) { hover = h } }
        .onTapGesture(perform: item.open)
        .tappable("\(item.title), \(item.meta), \(item.status)", action: item.open)
    }
}

// MARK: - Side panel

let playedTint = Color(red: 0.078, green: 0.659, blue: 0.478)    // #14A87A, validated against Theme.rail
let libraryTint = Color(red: 0.42, green: 0.482, blue: 0.949)    // #6B7BF2

struct SidePanel: View {
    let games: [Game]
    let library: Library
    @ObservedObject var catalog: StoreCatalog
    @ObservedObject var builds: BuildQueue
    let actions: Actions

    private var totalPlay: Double { library.playTime.values.reduce(0, +) }
    private var building: Game? { games.first { $0.state == .building } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    profile
                    searchField.padding(.bottom, 4)
                    playTile
                    statTile("Games ready", "\(games.filter { $0.state == .ready }.count)", "gamecontroller.fill") { readyIcons }
                    storage
                    buildTile
                    TasteRadar(games: games, library: library).padding(.top, 6)
                }
                .padding(18).padding(.bottom, 20)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            news.padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 44)
        }
        .raised(26, fill: Theme.rail)
    }

    private var profile: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SystemInfo.firstName).font(.ui(17, .bold)).foregroundStyle(.white).lineLimit(1)
                Label("Player", systemImage: "checkmark.seal.fill").font(.ui(11, .semibold)).foregroundStyle(mint)
            }
            Spacer()
            Avatar(size: 46, editable: true).overlay(Circle().strokeBorder(mint.opacity(0.7), lineWidth: 2).padding(-3).allowsHitTesting(false))
        }
    }

    /// Looks like the reference's search box; opens the app-wide search.
    private var searchField: some View {
        Button(action: actions.search) {
            HStack {
                Text("Search games…").font(.ui(13, .medium)).foregroundStyle(Theme.ink2)
                Spacer()
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Search games")
    }

    private func statTile<V: View>(_ label: String, _ value: String, _ icon: String, @ViewBuilder _ visual: () -> V) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(label, systemImage: icon).font(.ui(11, .semibold)).foregroundStyle(Theme.ink2)
                Text(value).font(.ui(17, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            visual()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .raised(16)
        .accessibilityElement(children: .combine)
    }

    /// Total play time, with the last 14 days as a sparkline.
    private var playTile: some View {
        let days = (0..<14).reversed().map { d -> Double in
            let day = Calendar.current.date(byAdding: .day, value: -d, to: Date())!
            return library.daily[Library.dayKey.string(from: day)] ?? 0
        }
        return statTile("Play time", totalPlay > 0 ? formatPlayTime(totalPlay) : "None yet", "clock.fill") {
            Sparkline(values: days, tint: .cyan)
                .frame(width: 66, height: 28)
                .help("Play time per day, last 14 days")
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("T7 storage", systemImage: "externaldrive.fill").font(.ui(11, .semibold)).foregroundStyle(Theme.ink2)
            HStack(alignment: .firstTextBaseline) {
                Text(SystemInfo.t7Free).font(.ui(17, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Text("\(Int(SystemInfo.t7UsedFraction * 100))% used").font(.ui(11, .semibold)).foregroundStyle(Theme.ink2)
            }
            ProgressBar(value: SystemInfo.t7UsedFraction, tint: libraryTint).frame(height: 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .raised(16)
        .accessibilityElement(children: .combine)
    }

    private var readyIcons: some View {
        HStack(spacing: -10) {
            ForEach(games.filter { $0.state == .ready }.prefix(4)) { g in
                if let icon = g.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        .clipShape(Circle()).overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
                }
            }
        }
    }

    @ViewBuilder private var buildTile: some View {
        if let b = building {
            Button { actions.go(.builds) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Building", systemImage: "hammer.fill").font(.ui(11, .semibold)).foregroundStyle(.orange)
                        Spacer()
                        Text("\(Int((b.build?.overall ?? 0) * 100))%").font(.ui(13, .bold)).monospacedDigit().foregroundStyle(.white)
                    }
                    Text(b.name).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1)
                    ProgressBar(value: b.build?.overall ?? 0, tint: .orange).frame(height: 6)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.orange.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(PressStyle())
        }
    }

    /// The reference's "Gaming News" card: the newest game in nxnative, with a big controller
    /// breaking out of its top corner.
    @ViewBuilder private var news: some View {
        if let g = catalog.featured.first {
            Button { actions.store(g) } label: {
                ZStack(alignment: .bottomLeading) {
                    Thumb(url: g.image, max: 700).frame(height: 118).clipped()
                    LinearGradient(colors: [.clear, Theme.panel.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEW IN NXNATIVE").font(.ui(11, .heavy)).tracking(1.4).foregroundStyle(mint)
                        Text(g.name).font(.ui(15, .bold)).foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(14)
                }
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let pad = Bundled.image("Art", "controller.png") {
                        Image(nsImage: pad).resizable().interpolation(.high).frame(width: 92, height: 92)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
                            .rotationEffect(.degrees(-14)).offset(x: 12, y: -46)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("New in nxnative: \(g.name). Shows its details")
        }
    }
}

/// A single-series trend line; the tile's label names it, so it has no legend.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        GeometryReader { g in
            let top = max(values.max() ?? 0, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height - 3 - (g.size.height - 6) * CGFloat(v / top))
            }
            ZStack {
                smooth(pts).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2)).position(last)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Play time per day, last \(values.count) days")
        .accessibilityValue(values.map { formatPlayTime($0) }.joined(separator: ", "))
    }

    private func smooth(_ p: [CGPoint]) -> Path {
        Path { path in
            guard let first = p.first else { return }
            path.move(to: first)
            for i in 1..<p.count {
                let a = p[i - 1], b = p[i], mx = (a.x + b.x) / 2
                path.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
            }
        }
    }
}

/// "Your taste": the genres you own against the genres you play, on one radial scale.
struct TasteRadar: View {
    let games: [Game]
    let library: Library
    @State private var hover: Int?

    private var axes: [(name: String, owned: Double, played: Double)] {
        var owned: [String: Double] = [:], played: [String: Double] = [:]
        for g in games {
            for genre in Catalog.genres(of: g) {
                owned[genre, default: 0] += 1
                played[genre, default: 0] += library.playTime[g.id] ?? 0
            }
        }
        let names = owned.keys.sorted { owned[$0]! != owned[$1]! ? owned[$0]! > owned[$1]! : $0 < $1 }.prefix(6)
        let maxOwned = max(owned.values.max() ?? 1, 1), maxPlayed = max(played.values.max() ?? 0, 1)
        return names.map { ($0, owned[$0]! / maxOwned, (played[$0] ?? 0) / maxPlayed) }
    }

    var body: some View {
        let a = axes
        VStack(alignment: .leading, spacing: 10) {
            Text("Your taste").font(.ui(15, .bold)).foregroundStyle(.white)
            HStack(spacing: 14) {
                legend(playedTint, "Played", dashed: false)
                legend(libraryTint, "Owned", dashed: true)
            }
            if a.count < 3 {
                Text("Install a few more games to see which genres you lean to.")
                    .font(.ui(12, .medium)).foregroundStyle(Theme.ink2)
            } else {
                GeometryReader { g in
                    let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                    // room around the rim for the genre names
                    let r = min(g.size.width / 2 - 46, g.size.height / 2 - 18)
                    ZStack {
                        ForEach(1...4, id: \.self) { ring in
                            polygon(Array(repeating: Double(ring) / 4, count: a.count), c, r)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }
                        ForEach(a.indices, id: \.self) { i in
                            Path { p in p.move(to: c); p.addLine(to: point(i, a.count, 1, c, r)) }.stroke(.white.opacity(0.08), lineWidth: 1)
                        }
                        polygon(a.map(\.owned), c, r).stroke(libraryTint, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        polygon(a.map(\.played), c, r).fill(playedTint.opacity(0.28))
                        polygon(a.map(\.played), c, r).stroke(playedTint, lineWidth: 2)
                        ForEach(a.indices, id: \.self) { i in
                            Text(a[i].name).font(.ui(11, hover == i ? .bold : .semibold))
                                .foregroundStyle(hover == i ? .white : Theme.ink2)
                                .fixedSize()
                                .position(point(i, a.count, 1.0 + 16 / r, c, r))
                                .onHover { hover = $0 ? i : nil }
                                .help("\(a[i].name): \(Int(a[i].owned * 100))% of your top genre owned, \(Int(a[i].played * 100))% of your top genre's play time")
                        }
                    }
                }
                .frame(height: 170)
                .accessibilityElement()
                .accessibilityLabel("Your taste by genre")
                .accessibilityValue(a.map { "\($0.name): owned \(Int($0.owned * 100))%, played \(Int($0.played * 100))%" }.joined(separator: "; "))
            }
        }
        .padding(16)
        .raised(16)
    }

    private func legend(_ c: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().stroke(c, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : [])).frame(width: 14, height: 2)
            Text(label).font(.ui(11, .semibold)).foregroundStyle(Theme.ink2)
        }
    }

    private func point(_ i: Int, _ n: Int, _ v: Double, _ c: CGPoint, _ r: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
        return CGPoint(x: c.x + CGFloat(cos(angle) * v) * r, y: c.y + CGFloat(sin(angle) * v) * r)
    }

    private func polygon(_ vals: [Double], _ c: CGPoint, _ r: CGFloat) -> Path {
        Path { p in
            for (i, v) in vals.enumerated() {
                let pt = point(i, vals.count, max(v, 0.04), c, r)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
        }
    }
}
