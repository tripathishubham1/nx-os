// The Store: every game nxnative supports, read from the local nxnative checkout (its README's
// gallery, docs/images/gallery.tsv and dm/games/README.md), refreshed with a git pull. Games are
// installed from the player's own dumps and built right there; nothing is downloaded.
import SwiftUI
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

struct StoreGame: Identifiable, Hashable {
    let id: String          // title ID
    let name: String
    let note: String        // "60 fps with 1.2.0", "no Mii heads", …
    let image: URL
    var order: Int          // position in the gallery; newer games come last
    var size: String?       // "~4 GB"
    var tested: String?     // the update nxnative was brought up on
    var engine: String?
    var graphics: String?

    var sizeGB: Double? {
        guard let s = size, let m = s.firstMatch(of: #/([\d.]+)\s*(GB|MB)/#), let v = Double(m.1) else { return nil }
        return m.2 == "MB" ? v / 1000 : v
    }
    var trailerURL: URL {
        let q = "\(name) Nintendo Switch official trailer".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "https://www.youtube.com/results?search_query=\(q)")!
    }
    var regional: Bool { name.contains("release)") }
    var notesURL: URL { URL(string: "https://github.com/seedds/nxnative/blob/main/dm/games/\(id)/README.md")! }
}

final class StoreCatalog: ObservableObject {
    @Published var games: [StoreGame] = []
    @Published var updated = ""
    @Published var refreshing = false
    @Published var loaded = false

    init() { load() }

    func load() {
        let root = nxnativeRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.parse(root)
            let when = shell("/usr/bin/git", ["-C", root.path, "log", "-1", "--format=%cr"])
            DispatchQueue.main.async { self.games = list; self.updated = when; self.loaded = true }
        }
    }

    /// The banner: the six games nxnative added most recently.
    var featured: [StoreGame] { Array(games.suffix(6).reversed()) }

    func refresh() {
        refreshing = true
        DispatchQueue.global().async {
            _ = shell("/usr/bin/git", ["-C", nxnativeRoot.path, "pull", "--ff-only"])
            DispatchQueue.main.async { self.refreshing = false; self.load() }
        }
    }

    private static func parse(_ root: URL) -> [StoreGame] {
        guard let tsv = try? String(contentsOf: root.appendingPathComponent("docs/images/gallery.tsv"), encoding: .utf8) else { return [] }
        let readme = (try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        let table = (try? String(contentsOf: root.appendingPathComponent("dm/games/README.md"), encoding: .utf8)) ?? ""

        // image file -> "~4 GB" from the README's gallery captions
        var sizes: [String: String] = [:]
        for m in readme.matches(of: #/src="docs/images/([^"]+)"[^>]*><br><sub><b>.*?</b><br>([^<]*)</sub>/#) {
            let caption = String(m.2)
            sizes[String(m.1)] = caption.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces)
        }
        // title ID -> tested update, engine, graphics
        var info: [String: (String, String, String)] = [:]
        for line in table.split(separator: "\n") where line.hasPrefix("| [") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 7 else { continue }
            let tid = cells[2].replacingOccurrences(of: "`", with: "")
            info[tid] = (cells[3], cells[5], cells[6])
        }
        var out: [StoreGame] = []
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 4, !c[3].isEmpty else { continue }
            var g = StoreGame(id: c[3].uppercased(), name: c[1], note: c[2],
                              image: root.appendingPathComponent("docs/images/\(c[0])"), order: out.count)
            g.size = sizes[c[0]]
            if let i = info[g.id] { g.tested = i.0; g.engine = i.1; g.graphics = i.2 }
            out.append(g)
        }
        // supported games the gallery has no screenshot for (mostly regional releases): they borrow the
        // art of the release they share a name with
        let seen = Set(out.map(\.id))
        for line in table.split(separator: "\n") where line.hasPrefix("| [") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 7, let m = cells[1].firstMatch(of: #/\[([^\]]+)\]/#) else { continue }
            let tid = cells[2].replacingOccurrences(of: "`", with: "").uppercased()
            guard !seen.contains(tid) else { continue }
            let full = String(m.1)
            let parts = full.components(separatedBy: ", ")
            let base = parts.first ?? full
            let name = parts.count > 1 ? "\(base) (\(parts.dropFirst().joined(separator: ", ")))" : full
            let sibling = out.first { $0.name.matches(base) || base.matches($0.name) }
            var g = StoreGame(id: tid, name: name, note: "", image: sibling?.image ?? root.appendingPathComponent("docs/images/none.jpg"),
                              order: 0)
            g.size = sibling?.size
            g.tested = cells[3]; g.engine = cells[5]; g.graphics = cells[6]
            // next to the release it belongs to, not at the end (the end is where "new" games are)
            let at = sibling.flatMap { s in out.firstIndex { $0.id == s.id } }.map { $0 + 1 } ?? 0
            out.insert(g, at: at)
        }
        // sizes: the gallery captions no longer give them; each game's notes may ("IPA at about 6 GB")
        for i in out.indices where out[i].size == nil {
            let notes = (try? String(contentsOf: root.appendingPathComponent("dm/games/\(out[i].id)/README.md"), encoding: .utf8)) ?? ""
            if let m = notes.firstMatch(of: #/IPA (?:is |at |as )?about ([\d.]+) ?(GB|MB)/#) { out[i].size = "~\(m.1) \(m.2)" }
        }
        for i in out.indices { out[i].order = i }
        return out
    }
}

/// Screenshots are big JPEGs on the T7: decode them off the main thread at the size they're shown.
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)

    func image(_ url: URL, max: Int = 900, done: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)#\(max)" as NSString
        if let img = cache.object(forKey: NSURL(string: key as String) ?? url as NSURL) { done(img); return }
        queue.async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: max,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            if let img { self.cache.setObject(img, forKey: NSURL(string: key as String) ?? url as NSURL) }
            DispatchQueue.main.async { done(img) }
        }
    }
}

struct Thumb: View {
    let url: URL
    var max = 900
    @State private var img: NSImage?
    @State private var missing = false
    var body: some View {
        // the filled image sits in an overlay so it can never grow the layout
        LinearGradient(colors: [Theme.card.mix(with: .white, by: 0.06), Theme.card], startPoint: .top, endPoint: .bottom)
            .overlay {
                if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
                else if missing { Image(systemName: "gamecontroller.fill").font(.system(size: 26)).foregroundStyle(Theme.ink2.opacity(0.6)) }
            }
            .clipped()
            .onAppear { Thumbs.shared.image(url, max: max) { i in withAnimation(.easeOut(duration: 0.35)) { img = i; missing = i == nil } } }
    }
}

// MARK: - Store page

enum StoreStatus { case installed, building, available }

struct StorePage: View {
    @ObservedObject var catalog: StoreCatalog
    let library: Library
    @ObservedObject var builds: BuildQueue
    let query: String
    let actions: Actions
    @Binding var detail: StoreGame?
    @Binding var trailer: StoreGame?
    @Binding var featured: Int
    @State private var heroHover = false
    @State private var filter = "Featured"
    @AppStorage("storeSort") private var sort = "az"

    private static let nintendo = ["Zelda", "Mario", "Kirby", "Donkey Kong", "Metroid", "Pikmin", "Yoshi", "Luigi", "Smash", "Splatoon", "Xenoblade", "Fire Emblem", "Animal Crossing"]
    private var filters: [(String, String, [StoreGame])] {
        let g = catalog.games
        return [("Featured", "sparkles", g), ("All", "square.grid.2x2.fill", g),
                ("Your games", "checkmark.seal.fill", g.filter { status($0) != .available }),
                ("60 fps", "gauge.with.dots.needle.67percent", g.filter { $0.note.contains("60 fps") }),
                ("Pokémon", "circle.circle.fill", g.filter { $0.name.contains("Pokémon") }),
                ("Nintendo", "crown.fill", g.filter { n in Self.nintendo.contains(where: n.name.contains) }),
                ("Quick to build", "bolt.fill", g.filter { ($0.sizeGB ?? 99) < 2 }),
                ("Regional releases", "globe.asia.australia.fill", g.filter(\.regional))]
    }
    private func sorted(_ list: [StoreGame]) -> [StoreGame] {
        switch sort {
        case "new": return list.sorted { $0.order > $1.order }
        case "size": return list.sorted { ($0.sizeGB ?? 999) < ($1.sizeGB ?? 999) }
        default: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func status(_ g: StoreGame) -> StoreStatus {
        if library.games.contains(where: { $0.titleID.uppercased() == g.id && $0.state == .ready }) { return .installed }
        if library.games.contains(where: { $0.titleID.uppercased() == g.id && $0.state == .building }) { return .building }
        return .available
    }
    private var featuredGames: [StoreGame] { catalog.featured }
    private var filtered: [StoreGame] {
        catalog.games.filter { $0.name.matches(query) || $0.id.matches(query) }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if catalog.games.isEmpty {
                        emptyState(catalog.loaded ? "shippingbox" : "hourglass",
                                   catalog.loaded ? "The game list isn't available" : "Loading the game list…",
                                   catalog.loaded ? "NX OS reads it from nxnative at \(nxnativeRoot.path). Check the T7 is connected, then refresh." : "")
                    } else if !query.isEmpty && filtered.isEmpty {
                        emptyState("magnifyingglass", "No games match “\(query)”", "Try a shorter name, or a title ID like 0100…")
                    } else if query.isEmpty && filter != "Featured" {
                        let list = sorted(filters.first { $0.0 == filter }?.2 ?? [])
                        SectionTitle(title: "\(filter) · \(list.count) \(list.count == 1 ? "game" : "games")")
                        if list.isEmpty { emptyState("tray", "Nothing here yet", filter == "Your games" ? "Games you install from the Store show up here." : "") }
                        else { grid(list) }
                    } else if query.isEmpty {
                        if !featuredGames.isEmpty { hero.frame(height: max(240, min(360, geo.size.height * 0.42))) }
                        shelf("New in nxnative", "sparkles", Array(catalog.games.suffix(14).reversed()))
                        shelf("Your games", "checkmark.seal.fill", catalog.games.filter { status($0) != .available })
                        shelf("Runs at 60 fps", "gauge.with.dots.needle.67percent", catalog.games.filter { $0.note.contains("60 fps") })
                        shelf("Pokémon", "sparkles", catalog.games.filter { $0.name.contains("Pokémon") })
                        shelf("Zelda, Mario & friends", "crown.fill",
                              catalog.games.filter { ["Zelda", "Mario", "Kirby", "Donkey Kong", "Metroid", "Pikmin", "Yoshi", "Luigi", "Smash"].contains(where: $0.name.contains) })
                        shelf("Quick to build", "bolt.fill", catalog.games.filter { ($0.sizeGB ?? 99) < 2 }.sorted { ($0.sizeGB ?? 0) < ($1.sizeGB ?? 0) })
                        SectionTitle(title: "All \(catalog.games.count) games")
                        grid(sorted(catalog.games))
                    } else {
                        grid(sorted(filtered))
                    }
                }
                .padding(.top, 4).padding(.bottom, 24)
            }
            .defaultScrollAnchor(.top)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.015),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .onAppear { if catalog.loaded { catalog.load() } }
        .onReceive(Timer.publish(every: 7, on: .main, in: .common).autoconnect()) { _ in
            // the banner holds still while the pointer is on it
            guard !featuredGames.isEmpty, !heroHover, detail == nil, trailer == nil else { return }
            withAnimation(.easeInOut(duration: 0.9)) { featured = (featured + 1) % featuredGames.count }
        }
    }

    private func emptyState(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.ui(17, .bold)).foregroundStyle(.white)
            if !detail.isEmpty { Text(detail).font(.ui(13, .medium)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "bag.fill", title: query.isEmpty ? "Store" : "Store results for “\(query)”",
                       subtitle: "\(catalog.games.count) games run natively with nxnative · list updated \(catalog.updated)") {
                HStack(spacing: 10) {
                    SegmentedPills(options: [("az", "A–Z"), ("new", "Newest"), ("size", "Smallest")], selection: $sort)
                    IconButton(icon: catalog.refreshing ? "hourglass" : "arrow.clockwise", help: "Refresh the list from nxnative") { catalog.refresh() }
                        .disabled(catalog.refreshing)
                }
            }
            if query.isEmpty {
                ArrowScroller {
                    HStack(spacing: 10) {
                        ForEach(filters, id: \.0) { f in
                            Chip(label: f.0 + (f.0 == "Featured" ? "" : " \(f.2.count)"), selected: filter == f.0, icon: f.1) {
                                Sfx.move(); withAnimation(spring) { filter = f.0 }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .padding(.horizontal, -12)
            }
        }
    }

    private var hero: some View {
        let g = featuredGames[min(featured, featuredGames.count - 1)]
        return ZStack(alignment: .bottomLeading) {
            Color.clear.overlay {
                ForEach(featuredGames.indices, id: \.self) { i in
                    if i == featured {
                        KenBurns { Thumb(url: featuredGames[i].image, max: 1800) }.transition(.opacity)
                    }
                }
            }
            .clipped()
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.1), .clear], startPoint: .bottomLeading, endPoint: .topTrailing)
            VStack(alignment: .leading, spacing: 12) {
                Text("NEW IN NXNATIVE").font(.ui(11, .heavy)).tracking(1.8).foregroundStyle(.white.opacity(0.75))
                Text(g.name).font(.ui(38, .heavy)).foregroundStyle(.white).lineLimit(2).shadow(color: .black.opacity(0.4), radius: 10)
                    .id(g.id).transition(.opacity.combined(with: .move(edge: .bottom)))
                metaLine(g).foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 10) {
                    primaryButton(g)
                    PillButton(title: "Trailer", icon: "play.rectangle.fill") { trailer = g }
                    PillButton(title: "Details", icon: "info.circle") { detail = g }
                }
            }
            .padding(30)
            HStack(spacing: 0) {
                ForEach(featuredGames.indices, id: \.self) { i in
                    Button { withAnimation(.easeInOut(duration: 0.6)) { featured = i } } label: {
                        Capsule().fill(.white.opacity(i == featured ? 1 : 0.4)).frame(width: i == featured ? 20 : 6, height: 6)
                            .frame(width: i == featured ? 28 : 16, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(featuredGames[i].name)")
                }
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .contentShape(Rectangle())
        .onTapGesture { detail = g }
        .onHover { heroHover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured: \(g.name)")
    }

    @ViewBuilder private func shelf(_ title: String, _ icon: String, _ items: [StoreGame]) -> some View {
        if !items.isEmpty {
            ScrollSection(spacing: 4, bleed: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(Theme.ink2)
                    Text(title).font(.ui(20, .bold)).foregroundStyle(.white)
                    Text("\(items.count)").font(.ui(12, .bold)).foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.1)))
                }
            } content: {
                LazyHStack(spacing: 18) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, g in
                        StoreCard(game: g, status: status(g), width: 270, index: i) { detail = g }
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 12)
            }

        }
    }

    private func grid(_ items: [StoreGame]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 18)], spacing: 22) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, g in
                StoreCard(game: g, status: status(g), width: nil, index: i % 8) { detail = g }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func primaryButton(_ g: StoreGame) -> some View {
        switch status(g) {
        case .installed:
            PillButton(title: "Play", icon: "play.fill", prominent: true) {
                if let lg = library.games.first(where: { $0.titleID.uppercased() == g.id }) { actions.play(lg) }
            }
        case .building:
            PillButton(title: "View build", icon: "hammer.fill", prominent: true, tint: .orange) { actions.go(.builds) }
        case .available:
            PillButton(title: "Install from my dump…", icon: "arrow.down.circle.fill", prominent: true) { installDump(g, builds: builds) }
        }
    }
}

func metaLine(_ g: StoreGame) -> some View {
    let parts = [g.size, g.note.isEmpty ? nil : g.note, g.tested.map { "Tested on \($0)" }].compactMap { $0 }
    return Text(parts.joined(separator: "  ·  ")).font(.ui(12, .semibold)).lineLimit(1)
}

/// Lets the player choose their own dump of this game; it is named with the title ID and built.
func installDump(_ g: StoreGame, builds: BuildQueue, done: ((String?) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = ["nsp", "xci", "nsz", "xcz"].compactMap { UTType(filenameExtension: $0) }
    panel.prompt = "Install"
    panel.message = "Choose your dump of \(g.name), and its update if you have it"
    guard panel.runModal() == .OK else { return }
    builds.install(panel.urls, titleID: g.id, name: g.name) { done?($0) }
}

struct StoreCard: View {
    let game: StoreGame
    let status: StoreStatus
    let width: CGFloat?
    let index: Int
    let open: () -> Void
    @State private var hover = false
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Thumb(url: game.image, max: 700)
                    .scaleEffect(hover ? 1.06 : 1)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                badge.padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(hover ? 0.45 : 0.1), lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.5 : 0.3), radius: hover ? 22 : 10, y: hover ? 14 : 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1)
                Text([game.size, game.note.isEmpty ? nil : game.note].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.ui(12, .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .frame(width: width)
        .offset(y: hover ? -5 : (shown ? 0 : 16))
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(snappy) { hover = h } }
        .onTapGesture(perform: open)
        .tappable([game.name, game.size, game.note, status == .installed ? "Installed" : status == .building ? "Building" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "), hint: "Shows details", action: open)
        .onAppear {
            if reduceMotion { shown = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(min(index, 10)) * 0.04)) { shown = true }
        }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .installed: tag("INSTALLED", .green)
        case .building: tag("BUILDING", .orange)
        case .available: EmptyView()
        }
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.ui(11, .heavy)).tracking(1).foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(c))
    }
}

/// A slow zoom and drift on artwork.
struct KenBurns<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            content
                .scaleEffect(1.06 + 0.04 * sin(s / 9))
                .offset(x: CGFloat(sin(s / 13)) * 12, y: CGFloat(cos(s / 11)) * 6)
        }
        .clipped()
    }
}

// MARK: - Detail and trailer

struct StoreDetail: View {
    let game: StoreGame
    let status: StoreStatus
    let library: Library
    @ObservedObject var builds: BuildQueue
    let actions: Actions
    let close: () -> Void
    let trailer: () -> Void
    @State private var problem: String?
    @State private var preview: Trailer?
    @State private var previewShown = false
    @State private var previewStopped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                KenBurns { Thumb(url: game.image, max: 1800) }
                    .frame(height: 340)
                if let preview {
                    // a muted, looping trailer behind the title; the overscan hides YouTube's chrome
                    VideoPlayer(videoID: preview.id, muted: true) { withAnimation(.easeInOut(duration: 1.0)) { previewShown = true } }
                        .frame(width: 760 * 1.25, height: 340 * 1.25)
                        .frame(width: 760, height: 340).clipped()
                        .opacity(previewShown ? 1 : 0)
                        .allowsHitTesting(false)
                }
                LinearGradient(colors: [.clear, Color(white: 0.09).opacity(0.6), Color(white: 0.09)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    if previewShown {
                        IconButton(icon: "pause.fill", help: "Stop the preview") { withAnimation(.easeOut(duration: 0.3)) { preview = nil; previewShown = false; previewStopped = true } }
                    }
                    IconButton(icon: "xmark", help: "Close (Esc)", action: close)
                }
                .padding(16)
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.name).font(.ui(34, .heavy)).foregroundStyle(.white)
                    metaLine(game).foregroundStyle(.white.opacity(0.75))
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 340)
            .clipped()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    primary
                    PillButton(title: "Watch trailer", icon: "play.rectangle.fill", action: trailer)
                    PillButton(title: "Compatibility notes", icon: "doc.text.magnifyingglass") { NSWorkspace.shared.open(game.notesURL) }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.ui(12, .semibold)).foregroundStyle(.yellow)
                }
                HStack(spacing: 12) {
                    fact("Title ID", game.id, "number")
                    if let size = game.size { fact("Size", size, "internaldrive") }
                    fact("Tested update", game.tested ?? "–", "checkmark.seal")
                    fact("Graphics", game.graphics ?? "–", "cpu")
                }
                if let e = game.engine {
                    fact("Engine", e, "gearshape.2").frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Install uses your own dump of this game (NSP, XCI, NSZ or XCZ) and its update, then builds it with nxnative for this Mac.")
                    .font(.ui(12, .medium)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(28)
        }
        .frame(width: 760)
        .onAppear {
            // no autoplaying video when the player asked for less motion
            guard !reduceMotion else { return }
            Trailers.find(game) { l in
                guard let first = l.first else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard !previewStopped else { return }
                    preview = first     // loads unseen; fades in once playing
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
    }

    @ViewBuilder private var primary: some View {
        switch status {
        case .installed:
            PillButton(title: "Play", icon: "play.fill", prominent: true) {
                if let g = library.games.first(where: { $0.titleID.uppercased() == game.id }) { close(); actions.play(g) }
            }
        case .building:
            PillButton(title: "View build", icon: "hammer.fill", prominent: true, tint: .orange) { close(); actions.go(.builds) }
        case .available:
            PillButton(title: "Install from my dump…", icon: "arrow.down.circle.fill", prominent: true) {
                installDump(game, builds: builds) { p in problem = p; if p == nil { close(); actions.go(.builds) } }
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon).font(.ui(11, .bold)).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.ui(14, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
    }
}

// MARK: - Trailers

struct Trailer: Identifiable, Hashable {
    let id: String      // YouTube video ID
    let title: String
    var thumb: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

/// Finds a game's trailers on YouTube (the first results of a search), cached for the session.
enum Trailers {
    private static var cache: [String: [Trailer]] = [:]

    static func find(_ g: StoreGame, done: @escaping ([Trailer]) -> Void) {
        if let hit = cache[g.id] { done(hit); return }
        var req = URLRequest(url: g.trailerURL)
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let html = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var out: [Trailer] = []
            for m in html.matches(of: #/"videoRenderer":\{"videoId":"([\w-]{11})".*?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"/#) {
                let id = String(m.1)
                guard !out.contains(where: { $0.id == id }) else { continue }
                let title = (try? JSONDecoder().decode(String.self, from: Data("\"\(m.2)\"".utf8))) ?? String(m.2)
                out.append(Trailer(id: id, title: title))
                if out.count == 8 { break }
            }
            DispatchQueue.main.async { if !out.isEmpty { cache[g.id] = out }; done(out) }
        }.resume()
    }
}

/// Plays one YouTube video through its embed player.
struct VideoPlayer: NSViewRepresentable {
    let videoID: String
    var muted = false
    var onReady: (() -> Void)? = nil

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onReady: (() -> Void)?
        func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
            // the embed page has loaded; give the player a moment to show its first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.onReady?() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        context.coordinator.onReady = onReady
        w.navigationDelegate = context.coordinator
        load(w)
        return w
    }
    func updateNSView(_ w: WKWebView, context: Context) {}   // a new video gets a new view (.id)

    private func load(_ w: WKWebView) {
        let params = "autoplay=1&cc_load_policy=0&rel=0&playsinline=1&modestbranding=1&iv_load_policy=3" + (muted ? "&mute=1&controls=0&loop=1&playlist=\(videoID)" : "")
        let html = """
        <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube.com/embed/\(videoID)?\(params)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
          referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: "https://nxos.app/"))
    }
}

/// A remote image (trailer thumbnails), faded in when it arrives.
struct RemoteThumb: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.06) }
        }
    }
}

struct TrailerSheet: View {
    let game: StoreGame
    let close: () -> Void
    @State private var list: [Trailer] = []
    @State private var playing: Trailer?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.red).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.name).font(.ui(15, .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(playing?.title ?? "Trailers").font(.ui(11, .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                IconButton(icon: "arrow.up.right.square", help: "Open on YouTube") {
                    NSWorkspace.shared.open(playing.map { URL(string: "https://www.youtube.com/watch?v=\($0.id)")! } ?? game.trailerURL)
                }
                IconButton(icon: "xmark", help: "Close (Esc)", action: close)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let playing {
                        VideoPlayer(videoID: playing.id).id(playing.id)
                    } else if loading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(.white.opacity(0.5))
                            Text("Couldn't load trailers").font(.ui(14, .bold)).foregroundStyle(.white)
                            PillButton(title: "Open on YouTube", icon: "arrow.up.right") { NSWorkspace.shared.open(game.trailerURL) }
                        }
                    }
                }
                if list.count > 1 {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("UP NEXT").font(.ui(11, .heavy)).tracking(1.6).foregroundStyle(.white.opacity(0.6)).padding(.leading, 2)
                            ForEach(list) { t in
                                TrailerRow(trailer: t, selected: t == playing) { withAnimation(snappy) { playing = t } }
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 250)
                    .background(Color.white.opacity(0.03))
                }
            }
        }
        .frame(width: 1120, height: 640)
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        .onAppear {
            Trailers.find(game) { l in
                withAnimation(.easeOut(duration: 0.25)) { list = l; playing = l.first; loading = false }
            }
        }
    }
}

struct TrailerRow: View {
    let trailer: Trailer
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RemoteThumb(url: trailer.thumb)
                    if selected {
                        Color.black.opacity(0.45)
                        Label("Playing", systemImage: "waveform").font(.ui(11, .bold)).foregroundStyle(.white)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(selected ? 0.8 : hover ? 0.35 : 0.08), lineWidth: selected ? 2 : 1))
                Text(trailer.title).font(.ui(11, .semibold)).foregroundStyle(.white.opacity(selected ? 1 : 0.7)).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .scaleEffect(hover ? 1.02 : 1)
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
    }
}
