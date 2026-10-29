// The Games, Builds, Stats and System pages, in the Home page's visual language: a header banner,
// raised navy cards, mint controls, and charts that follow the dataviz rules (one hue per series,
// thin marks, values on hover).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared

/// The banner at the top of a page: an icon tile, the title and a live summary, then its actions.
struct PageHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var art: NSImage? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(mint)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(mint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(24, .bold)).tracking(-0.4).foregroundStyle(.white)
                Text(subtitle).font(.ui(13, .medium)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .raised(24)
        .background {
            if let art {
                Color.clear.overlay(alignment: .trailing) {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).frame(width: 420)
                        .blur(radius: 24).opacity(0.28)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }
}

/// A themed segmented control: mint pill on the chosen option.
struct SegmentedPills: View {
    let options: [(String, String)]     // (tag, label)
    @Binding var selection: String
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                Button { withAnimation(snappy) { selection = o.0 } } label: {
                    Text(o.1).font(.ui(12, selection == o.0 ? .bold : .semibold))
                        .foregroundStyle(selection == o.0 ? Color(white: 0.06) : Theme.ink2)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background {
                            if selection == o.0 { Capsule().fill(mint).matchedGeometryEffect(id: "pill", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selection == o.0 ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.panel.opacity(0.9)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// A small rounded tile holding a row's icon.
struct IconTile: View {
    let icon: String
    var tint: Color = mint
    var body: some View {
        Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
    }
}

// MARK: - Games

struct GamesPage: View {
    let games: [Game]
    let library: Library
    let query: String
    let selectedID: String?
    let actions: Actions
    @State private var chip = "All"
    @AppStorage("gamesSort") private var sort = "name"

    private var shown: [Game] {
        let base = Catalog.filter(games, chip: chip, playTime: library.playTime, lastPlayed: library.lastPlayed)
        switch sort {
        case "recent": return base.sorted { (library.lastPlayed[$0.id] ?? .distantPast) > (library.lastPlayed[$1.id] ?? .distantPast) }
        case "time": return base.sorted { (library.playTime[$0.id] ?? 0) > (library.playTime[$1.id] ?? 0) }
        default: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(icon: "square.grid.2x2.fill", title: query.isEmpty ? "Your games" : "Results for “\(query)”",
                       subtitle: "\(shown.count) of \(library.games.count) \(library.games.count == 1 ? "game" : "games")"
                           + " · \(library.games.filter { $0.state == .ready }.count) ready to play") {
                SegmentedPills(options: [("name", "Name"), ("recent", "Recent"), ("time", "Play time")], selection: $sort)
            }
            ChipRow(chips: ["All", "Recent"] + Catalog.chips(for: games).filter { !["All", "Recent", "Trending"].contains($0) }, selected: $chip)
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.ink2)
                    Text(query.isEmpty ? "No games in this category" : "No games match “\(query)”").font(.ui(17, .bold)).foregroundStyle(.white)
                    Text("Try another category, or find more games in the Store.").font(.ui(13, .medium)).foregroundStyle(Theme.ink2)
                    PillButton(title: "Open Store", icon: "bag.fill") { actions.go(.store) }.padding(.top, 6)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 70)
                .raised(24)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 200), spacing: 28)], alignment: .leading, spacing: 30) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, g in
                            PopCard(game: g, selected: g.id == selectedID, index: i,
                                    meta: metaText(g, playTime: library.playTime, failed: library.failedStart),
                                    running: library.running.contains(g.id), warning: library.failedStart[g.id] != nil, actions: actions)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .padding(.horizontal, -12)
            }
        }
    }
}

// MARK: - Builds

struct BuildsPage: View {
    let games: [Game]
    @ObservedObject var builds: BuildQueue
    @ObservedObject var catalog: StoreCatalog
    var failed: [String: String] = [:]
    let actions: Actions
    @State private var problem: String?
    @State private var dropping = false

    private var building: [Game] { games.filter { $0.state == .building } }
    private var ready: [Game] { games.filter { $0.state == .ready } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(icon: "hammer.fill", title: "Builds",
                           subtitle: "\(ready.count) built · \(building.count + builds.queue.count) in progress · \(SystemInfo.t7Free) on \(SystemInfo.driveName)") {
                    HStack(spacing: 10) {
                        PillButton(title: "Games folder", icon: "folder") { NSWorkspace.shared.open(gamesRoot) }
                        CTAButton(title: "Install game", icon: "plus") { pick() }
                    }
                }
                if let note = problem ?? builds.message {
                    HStack(spacing: 12) {
                        IconTile(icon: "exclamationmark.triangle.fill", tint: .yellow)
                        Text(note).font(.ui(13, .semibold)).foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(14).raised(16, fill: Color(red: 0.25, green: 0.22, blue: 0.12))
                }
                if builds.keysPath == nil {
                    HStack(spacing: 12) {
                        IconTile(icon: "key.fill", tint: .yellow)
                        Text("No prod.keys found. Put yours in ~/.switch/prod.keys to build games.").font(.ui(13, .semibold)).foregroundStyle(.white)
                    }
                    .padding(14).raised(16)
                }
                if !building.isEmpty {
                    SectionTitle(title: "In progress")
                    ForEach(building) { g in BuildRow(game: g, builds: builds, actions: actions) }
                }
                if !builds.queue.isEmpty {
                    SectionTitle(title: "Up next", subtitle: "Builds run one at a time")
                    ForEach(builds.queue, id: \.self) { name in queuedRow(name) }
                }
                dropZone
                if !ready.isEmpty {
                    SectionTitle(title: "Built", subtitle: "Add a game's update to its folder, then rebuild it")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 18) {
                        ForEach(ready) { g in builtCard(g) }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var dropZone: some View {
        HStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down.on.square.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(mint)
                .frame(width: 56, height: 56).background(Circle().fill(mint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your game files here, or click to choose").font(.ui(15, .bold)).foregroundStyle(.white)
                Text("NSP, XCI, NSZ or XCZ dumps of your own games, with their updates. Each goes into its own folder and builds automatically.")
                    .font(.ui(12, .medium)).foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(dropping ? mint.opacity(0.1) : Theme.card.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).foregroundStyle(dropping ? mint : .white.opacity(0.2)))
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; group.leave() }
            }
            group.notify(queue: .main) { install(urls) }
            return true
        }
        .onTapGesture { pick() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Add game files")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["nsp", "xci", "nsz", "xcz"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Install"
        panel.message = "Choose your game dumps (and their updates)"
        if panel.runModal() == .OK { install(panel.urls) }
    }

    private func install(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        problem = nil
        builds.install(urls, known: catalog.games) { problem = $0 }
    }

    private func queuedRow(_ name: String) -> some View {
        HStack(spacing: 14) {
            IconTile(icon: "clock.fill", tint: Theme.ink2)
            Text(name).font(.ui(15, .bold)).foregroundStyle(.white)
            Spacer()
            PillButton(title: "Remove", icon: "xmark") { builds.cancelQueued(name) }
        }
        .padding(14).raised(18)
    }

    private func builtCard(_ g: Game) -> some View {
        let shot = catalog.games.first { $0.id == g.titleID.uppercased() }?.image
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let shot { Thumb(url: shot, max: 600) }
                    else if let icon = g.icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill) }
                    else { Theme.card }
                }
                .frame(height: 112).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, Theme.card], startPoint: .center, endPoint: .bottom)
                if let icon = g.icon {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        .padding(14).offset(y: 22)
                }
            }
            .frame(height: 112)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.name).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1)
                    if let why = failed[g.id] {
                        Label(why == "Won't start" ? "Won't start: open its log" : "Won't start: \(why.lowercased())",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.ui(12, .semibold)).foregroundStyle(.yellow).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Ready · v\(g.version)", systemImage: "checkmark.seal.fill").font(.ui(12, .semibold)).foregroundStyle(mint)
                    }
                }
                Spacer(minLength: 6)
                IconButton(icon: "arrow.clockwise", help: "Rebuild (after adding an update)") { builds.rebuild(g.folder.lastPathComponent) }
            }
            .padding(.horizontal, 14).padding(.top, 28).padding(.bottom, 14)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .raised(18)
        .contextMenu {
            Button("Rebuild") { builds.rebuild(g.folder.lastPathComponent) }
            Button("Show in Finder") { actions.reveal(g) }
            Button("Open Log") { actions.log(g) }
            Divider()
            Button("Delete Game…", role: .destructive) { actions.delete(g) }
        }
    }
}

/// A build in progress, live from nxnative's JSON stream: the overall ring, a step tracker, and the
/// current step's progress, size and time left.
struct BuildRow: View {
    let game: Game
    @ObservedObject var builds: BuildQueue
    let actions: Actions

    var body: some View {
        let b = game.build
        let overall = b?.overall ?? 0
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                    Circle().trim(from: 0, to: max(0.02, overall))
                        .stroke(mint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if let icon = game.icon {
                        Image(nsImage: icon).resizable().frame(width: 46, height: 46).clipShape(Circle()).opacity(0.3)
                    }
                    Text("\(Int(overall * 100))%").font(.ui(15, .bold)).monospacedDigit().foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                .frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(game.name).font(.ui(17, .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(game.app == nil ? "BUILDING" : "REBUILDING").font(.ui(11, .heavy)).tracking(1)
                            .foregroundStyle(Color(white: 0.06)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.orange))
                    }
                    if let b, b.n > 0 {
                        Text("Step \(b.k) of \(b.n) · \(b.stage)" + (b.step.isEmpty ? "" : " · \(b.step)"))
                            .font(.ui(13, .medium)).foregroundStyle(Theme.ink2).lineLimit(1)
                    } else {
                        Text("Starting…").font(.ui(13, .medium)).foregroundStyle(Theme.ink2)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    PillButton(title: "Log", icon: "doc.text") {
                        if let log = BuildQueue.log(for: game.folder.lastPathComponent) { NSWorkspace.shared.open(log) }
                    }
                    if builds.active == game.folder.lastPathComponent {
                        PillButton(title: "Stop", icon: "stop.fill") { builds.stop(game.folder.lastPathComponent) }
                            .help("Stops the build; the next build continues from where it got to")
                    }
                }
            }
            if let b, b.n > 0 {
                // one segment per step: done, current (filling) and still to come
                HStack(spacing: 4) {
                    ForEach(1...b.n, id: \.self) { i in
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.1))
                                Capsule().fill(mint)
                                    .frame(width: i < b.k ? g.size.width : i == b.k ? g.size.width * CGFloat(b.percent ?? 0) / 100 : 0)
                            }
                        }
                        .frame(height: 6)
                    }
                }
                HStack(spacing: 16) {
                    if let p = b.percent { Label("\(p)% of this step", systemImage: "chart.bar.fill").contentTransition(.numericText()) }
                    if let d = b.detail { Label(d, systemImage: "internaldrive") }
                    if let eta = b.eta { Label("\(eta) left in this step", systemImage: "clock") }
                }
                .font(.ui(12, .medium)).monospacedDigit().foregroundStyle(Theme.ink2)
            }
        }
        .padding(20)
        .raised(22)
        .animation(.easeOut(duration: 0.45), value: b)
    }
}

// MARK: - Stats

struct StatsPage: View {
    let games: [Game]
    let library: Library
    @State private var hoverDay: Int?

    private var ready: [Game] { games.filter { $0.state == .ready } }
    private var total: Double { library.playTime.values.reduce(0, +) }
    private var ranked: [Game] { ready.sorted { (library.playTime[$0.id] ?? 0) > (library.playTime[$1.id] ?? 0) } }
    private var days: [(label: String, date: Date, seconds: Double)] {
        (0..<14).reversed().map { d in
            let day = Calendar.current.date(byAdding: .day, value: -d, to: Date())!
            return (day.formatted(.dateTime.month(.abbreviated).day()), day, library.daily[Library.dayKey.string(from: day)] ?? 0)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                hero
                HStack(alignment: .top, spacing: 16) {
                    tile("Games ready", "\(ready.count)", "gamecontroller.fill", mint)
                    tile("Being built", "\(games.count - ready.count)", "hammer.fill", .orange)
                    tile("Most played", ranked.first.flatMap { (library.playTime[$0.id] ?? 0) > 0 ? $0.name : nil } ?? "None yet", "flame.fill", .pink)
                    tile("Last played", lastPlayedText, "clock.arrow.circlepath", .cyan)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        dailyChart
                        byGame
                    }
                    TasteRadar(games: games, library: library).frame(width: 300)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var lastPlayedText: String {
        guard let (id, date) = library.lastPlayed.max(by: { $0.value < $1.value }),
              let g = games.first(where: { $0.id == id }) else { return "Never" }
        return "\(g.name), \(date.formatted(.relative(presentation: .named)))"
    }

    private var hero: some View {
        HStack(spacing: 20) {
            Avatar(size: 76, editable: true).overlay(Circle().strokeBorder(mint.opacity(0.7), lineWidth: 2).padding(-4).allowsHitTesting(false))
            VStack(alignment: .leading, spacing: 4) {
                Text(SystemInfo.firstName).font(.ui(24, .bold)).foregroundStyle(.white)
                Label("Player · \(SystemInfo.chip)", systemImage: "checkmark.seal.fill").font(.ui(12, .semibold)).foregroundStyle(mint)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TOTAL PLAY TIME").font(.ui(11, .heavy)).tracking(1.4).foregroundStyle(Theme.ink2)
                Text(total > 0 ? formatPlayTime(total) : "None yet").font(.ui(38, .bold)).tracking(-0.8).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .raised(24)
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(icon: icon, tint: tint)
            Text(value).font(.ui(17, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.ui(12, .semibold)).foregroundStyle(Theme.ink2)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .raised(18)
        .accessibilityElement(children: .combine)
    }

    /// Play time per day, last 14 days: one series, so no legend; the value shows on hover.
    private var dailyChart: some View {
        let d = days
        let top = max(d.map(\.seconds).max() ?? 0, 60)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Play time, last 14 days").font(.ui(15, .bold)).foregroundStyle(.white)
                Spacer()
                Text(hoverDay.map { "\(d[$0].label): \(d[$0].seconds > 0 ? formatPlayTime(d[$0].seconds) : "none")" } ?? "Hover a day for its time")
                    .font(.ui(12, .semibold)).foregroundStyle(hoverDay == nil ? Theme.ink2 : .white).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(d.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(.clear)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(Color(red: 0.42, green: 0.48, blue: 0.95).opacity(hoverDay == nil || hoverDay == i ? 1 : 0.45))
                                .frame(height: max(2, 120 * d[i].seconds / top))
                                .padding(.horizontal, 3)
                        }
                        .frame(height: 120)
                        Text(i % 2 == 1 || i == d.count - 1 ? d[i].date.formatted(.dateTime.day()) : " ")
                            .font(.ui(11, .medium)).foregroundStyle(Theme.ink2)
                    }
                    .contentShape(Rectangle())
                    .onHover { hoverDay = $0 ? i : (hoverDay == i ? nil : hoverDay) }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
            .overlay {
                if d.allSatisfy({ $0.seconds == 0 }) {
                    Text("Daily play time is counted from today. Play a game and it shows up here.")
                        .font(.ui(12, .medium)).foregroundStyle(Theme.ink2).padding(.bottom, 24)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Play time per day, last 14 days")
            .accessibilityValue(d.map { "\($0.label): \($0.seconds > 0 ? formatPlayTime($0.seconds) : "none")" }.joined(separator: "; "))
        }
        .padding(18).raised(20)
    }

    private var byGame: some View {
        let maxT = max(1, ranked.compactMap { library.playTime[$0.id] }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Play time by game").font(.ui(15, .bold)).foregroundStyle(.white)
            if ranked.isEmpty { Text("No games yet").font(.ui(13, .medium)).foregroundStyle(Theme.ink2) }
            ForEach(ranked) { g in
                let t = library.playTime[g.id] ?? 0
                HStack(spacing: 14) {
                    if let icon = g.icon {
                        Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(g.name).font(.ui(13, .bold)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(t > 0 ? formatPlayTime(t) : "Not played yet").font(.ui(12, .semibold)).foregroundStyle(Theme.ink2)
                        }
                        ProgressBar(value: t / maxT, tint: Color(red: 0.42, green: 0.48, blue: 0.95))
                    }
                }
            }
        }
        .padding(18).raised(20)
    }
}

// MARK: - System

struct SystemPage: View {
    @ObservedObject var builds: BuildQueue
    @Binding var muted: Bool
    var folders: () -> Void = {}
    @AppStorage("fullscreenOnStart") private var fullscreenOnStart = false
    @AppStorage("skipWindowDefault") private var skipWindowDefault = true
    @AppStorage("introOnStart") private var introOnStart = true
    @AppStorage("cleanUpAfterBuild") private var cleanUpAfterBuild = true
    @State private var updateResult: String?
    @State private var nxVersion = SystemInfo.nxnativeVersion

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(icon: "gearshape.fill", title: "System", subtitle: "NX OS 2.0 · \(SystemInfo.chip) · \(SystemInfo.memory) · \(SystemInfo.macOS)") {
                    EmptyView()
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        group("Look & sound") {
                            toggle("speaker.wave.2.fill", "Sound effects", Binding(get: { !muted }, set: { muted = !$0; Sfx.muted = muted }))
                            divider
                            toggle("sparkles", "Boot animation", $introOnStart)
                            divider
                            toggle("arrow.up.left.and.arrow.down.right", "Start in full screen", $fullscreenOnStart)
                        }
                        group("Games") {
                            toggle("forward.fill", "Skip each game's settings window", $skipWindowDefault)
                            divider
                            toggle("trash.fill", "Delete build files after a build", $cleanUpAfterBuild,
                                   note: "Saves tens of GB per game. Your dumps are kept, but a rebuild starts from scratch.")
                            divider
                            row("folder.fill", "Games folder") {
                                HStack(spacing: 8) {
                                    PillButton(title: "Open", icon: "arrow.up.right") { NSWorkspace.shared.open(gamesRoot) }
                                    PillButton(title: "Change…", icon: "folder") { folders() }
                                }
                            }
                            divider
                            row("key.fill", "Keys") {
                                Text(builds.keysPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                                    .font(.ui(12, .medium)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                    }
                    VStack(spacing: 18) {
                        storage
                        group("nxnative") {
                            row("cpu", "Version") { Text(nxVersion).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink2) }
                            divider
                            row("arrow.down.circle.fill", "Updates") {
                                PillButton(title: builds.updating ? "Updating…" : "Check for updates", icon: "arrow.clockwise", prominent: true, tint: mint) {
                                    builds.updateNxnative { out in updateResult = out; nxVersion = SystemInfo.nxnativeVersion }
                                }
                                .disabled(builds.updating)
                            }
                            if let updateResult {
                                Text(updateResult).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink2)
                                    .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }
                            divider
                            row("chevron.left.forwardslash.chevron.right", "Source") {
                                HStack(spacing: 8) {
                                    PillButton(title: "Open", icon: "arrow.up.right") { NSWorkspace.shared.open(nxnativeRoot) }
                                    PillButton(title: "Change…", icon: "folder") { folders() }
                                }
                            }
                        }
                        group("Power") {
                            row("power", "Quit NX OS", tint: .red) { PillButton(title: "Quit", icon: "power", prominent: true, tint: Color(red: 1, green: 0.42, blue: 0.42)) { NSApp.terminate(nil) } }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var storage: some View {
        let used = SystemInfo.t7UsedFraction
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconTile(icon: "externaldrive.fill", tint: Color(red: 0.42, green: 0.48, blue: 0.95))
                Text("\(SystemInfo.driveName) storage").font(.ui(15, .bold)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(used * 100))% used").font(.ui(12, .semibold)).foregroundStyle(Theme.ink2)
            }
            Text(SystemInfo.t7Free).font(.ui(24, .bold)).foregroundStyle(.white)
            ProgressBar(value: used, tint: Color(red: 0.42, green: 0.48, blue: 0.95)).frame(height: 8)
        }
        .padding(18).raised(20)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 44) }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.ui(11, .heavy)).tracking(1.4).foregroundStyle(Theme.ink2).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .raised(20)
        }
    }

    private func row<C: View>(_ icon: String, _ label: String, tint: Color = mint, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 14) {
            IconTile(icon: icon, tint: tint)
            Text(label).font(.ui(13, .semibold)).foregroundStyle(.white)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 50)
    }

    private func toggle(_ icon: String, _ label: String, _ isOn: Binding<Bool>, note: String? = nil) -> some View {
        HStack(spacing: 14) {
            IconTile(icon: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.ui(13, .semibold)).foregroundStyle(.white)
                if let note { Text(note).font(.ui(11, .medium)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            Toggle(label, isOn: isOn).toggleStyle(.switch).tint(mint).labelsHidden()
        }
        .frame(minHeight: 50).padding(.vertical, note == nil ? 0 : 6)
    }
}
