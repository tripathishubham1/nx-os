// The NX OS shell: the glass frame, the system bar, page switching, notifications, controller and
// keyboard navigation, the launch flow and the boot animation.
// NXLIB_SNAPSHOT=<file.png> renders one frame offscreen and exits; NXLIB_PAGE=<home|library|games|
// store|builds|stats|system>, NXLIB_SELECT=<index>, NXLIB_PANEL=1 and NXLIB_H pick what it shows.
import SwiftUI
import AppKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    var gameID: String? = nil
    var crash = false        // offers the game's log instead of Play
}

struct OSView: View {
    @StateObject private var library = Library()
    @StateObject private var pad = Pad()
    @StateObject private var builds = BuildQueue()
    @StateObject private var catalog = StoreCatalog()
    @State private var page: Page = Page.allCases.first { $0.title.lowercased() == env["NXLIB_PAGE"] } ?? .home
    @State private var selectedID: String?
    @State private var query = ""
    @State private var searching = false
    @State private var optionsFor: String? = nil
    @State private var toast: Toast?
    @State private var storeDetail: StoreGame?
    @State private var trailer: StoreGame?
    @State private var storeFeatured = 0
    @State private var intro = !isSnapshot && UserDefaults.standard.object(forKey: "introOnStart") as? Bool ?? true
    @State private var flash = 0.0
    @State private var setup = !Paths.configured || env["NXLIB_SETUP"] == "1"
    @State private var editingFolders = false
    @State private var muted = Sfx.muted
    @State private var wasBuilding: Set<String> = []
    @AppStorage("fullscreenOnStart") private var fullscreenOnStart = false
    @AppStorage("skipWindowDefault") private var skipWindowDefault = true
    @AppStorage("skipWindow") private var skipWindowStore = "{}"
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool

    /// The library, with games NX OS is building or rebuilding shown as building, with live progress.
    private var allGames: [Game] {
        library.games.map { g in
            let f = g.folder.lastPathComponent
            return builds.activeIPhone && builds.active == f ? g : builds.live[f].map { g.rebuilding($0) } ?? g
        }
    }
    private var games: [Game] {
        guard !query.isEmpty else { return allGames }
        return allGames.filter { $0.name.matches(query) || Catalog.genres(of: $0).contains { $0.matches(query) } }
    }
    private var current: Game? { allGames.first { $0.id == selectedID } ?? allGames.first }
    private var buildingCount: Int { allGames.filter { $0.state == .building }.count + builds.queue.count }

    private var actions: Actions {
        Actions(play: { play($0) },
                open: { g in Sfx.move(); withAnimation(spring) { selectedID = g.id; page = .library } },
                options: { g in
                    // one overlay at a time, and game options only where a game is selected
                    guard page.browses, page != .store, storeDetail == nil, trailer == nil else { return }
                    Sfx.panel(); withAnimation(spring) { selectedID = g.id; optionsFor = g.id }
                },
                reveal: { library.reveal($0) },
                log: { g in
                    if g.state == .building, let l = BuildQueue.log(for: g.folder.lastPathComponent) { NSWorkspace.shared.open(l) }
                    else { library.openLog(g) }
                },
                go: { p in go(p) },
                store: { g in
                    go(.store)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Sfx.panel(); withAnimation(spring) { storeDetail = g } }
                },
                search: { if !searching { toggleSearch() } else { searchFocused = true } },
                delete: { g in
                    library.delete(g) { msg in
                        if selectedID == g.id { selectedID = nil }
                        show(Toast(title: msg, subtitle: "Space on \(SystemInfo.driveName): \(SystemInfo.t7Free)"))
                    }
                })
    }

    var body: some View {
        ZStack {
            Color.clear
            if setup || editingFolders {
                SetupView(editing: editingFolders) { finishSetup() }.transition(.opacity)
            } else if !library.driveMounted {
                VStack(spacing: 22) {
                    message("externaldrive.badge.xmark", "Can't find your games folder",
                            "NX OS reads your games from \((gamesRoot.path as NSString).abbreviatingWithTildeInPath). Connect its drive, or choose another folder.")
                    PillButton(title: "Choose another folder", icon: "folder", prominent: true, tint: mint) { editingFolders = true }
                }
            } else {
                frame
            }
            if page != .store, let id = optionsFor, let g = library.games.first(where: { $0.id == id }), g.state == .ready { optionsLayer(g) }
            if let id = library.launching, let g = library.games.first(where: { $0.id == id }) { launchOverlay(g) }
            if let g = storeDetail { storeDetailLayer(g) }
            if let g = trailer { trailerLayer(g) }
            if let toast { toastView(toast) }
            Color.white.opacity(flash).allowsHitTesting(false)
            if intro { Intro().transition(.opacity) }
        }
        .background(Backdrop(game: current))
        // the toolbar only exists to inset the window buttons; nothing should shift under it
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1100, minHeight: 720)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear(perform: setUp)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .return, .space, .escape, .tab]) { k in
            if setup || editingFolders { return .ignored }
            if searchFocused && k.key != .escape { return .ignored }
            switch k.key {
            case .leftArrow: move(-1)
            case .rightArrow: move(1)
            case .return, .space: primary()
            case .escape: back()
            default: switchPage(k.modifiers.contains(.shift) ? -1 : 1)
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234567smfMSF/")) { k in
            if searchFocused || setup || editingFolders { return .ignored }
            switch k.characters.lowercased() {
            case "s": if let g = current { actions.options(g) }
            case "m": muted.toggle(); Sfx.muted = muted
            case "f", "/": if !searching { toggleSearch() } else { searchFocused = true }
            default: if let n = Int(k.characters), let p = Page(rawValue: n - 1) { go(p) }
            }
            return .handled
        }
        .onChange(of: allGames) { _, gs in noticeFinishedBuilds(gs) }
        .onChange(of: library.crashed?.id) { _, id in
            guard let id, let g = library.games.first(where: { $0.id == id }) else { return }
            show(Toast(title: "\(g.name) stopped while starting", subtitle: crashHint(g), gameID: g.id, crash: true))
            library.failedStart[g.id] = shortHint(g)
            library.crashed = nil
        }
        .onChange(of: query) { _, q in if !q.isEmpty && ![.games, .home, .store].contains(page) { go(.games) } }
    }

    // MARK: Frame

    private func toggleSearch() {
        withAnimation(spring) {
            if searching { searching = false; query = "" } else { searching = true }
        }
        if searching { DispatchQueue.main.async { searchFocused = true } } else { focused = true }
    }

    private var frame: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, searching: searching, muted: $muted, buildingCount: buildingCount,
                    padConnected: pad.connected, go: go, search: toggleSearch)

            VStack(spacing: 0) {
            if searching {
                SearchBar(query: $query, focus: $searchFocused,
                          placeholder: page == .store ? "Search the Store: name or title ID" : "Search your games",
                          submit: { if ![.store, .home].contains(page) { go(.games) } },
                          close: toggleSearch)
                    .padding(.horizontal, 24).padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, page == .home ? 16 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(page)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.985, anchor: .top)),
                                          removal: .opacity.combined(with: .scale(scale: 0.99, anchor: .top))))
            // Home puts the hints under its main column, so its side panel can run to the bottom
            if page != .home { footer.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14) }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .store: StorePage(catalog: catalog, library: library, builds: builds, query: query, actions: actions,
                               detail: Binding(get: { storeDetail }, set: { g in Sfx.panel(); withAnimation(spring) { storeDetail = g } }),
                               trailer: Binding(get: { trailer }, set: { g in withAnimation(spring) { trailer = g } }),
                               featured: $storeFeatured)
        case .home: HomePage(games: games, library: library, catalog: catalog, builds: builds, selectedID: selectedID, query: query,
                             actions: actions, footer: AnyView(footer))
        case .library: LibraryPage(games: games, library: library, selectedID: $selectedID, actions: actions)
        case .games: GamesPage(games: games, library: library, query: query, selectedID: selectedID, actions: actions)
        case .builds: BuildsPage(games: allGames, builds: builds, catalog: catalog, failed: library.failedStart, actions: actions)
        case .stats: StatsPage(games: allGames, library: library)
        case .system: SystemPage(builds: builds, muted: $muted, folders: { editingFolders = true })
        }
    }

    private var footer: some View {
        HStack(spacing: 22) {
            if page.browses {
                Label {
                    Text(page == .library ? "Browse" : page == .store ? "Featured games" : "Select")
                } icon: {
                    Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold))
                }
                .font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if page == .store {
                ButtonHint(glyph: "A", label: "Details")
            } else if page.browses {
                ButtonHint(glyph: "A", label: "Play")
                ButtonHint(glyph: "Y", label: "Options")
            }
            ButtonHint(glyph: "B", label: "Back")
            ButtonHint(glyph: "L R", label: "Switch tabs")
            ButtonHint(glyph: "", label: "System", symbol: "line.3.horizontal")
        }
    }

    // MARK: Overlays

    private func optionsLayer(_ g: Game) -> some View {
        HStack {
            Spacer()
            SettingsPanel(game: g, settings: library.settings(for: g), skipWindow: skipBinding(g)) {
                Sfx.panel(); withAnimation(spring) { optionsFor = nil }
            }
            .id(g.id)
            .padding(.top, 40).padding(.bottom, 70).padding(.trailing, 40)
        }
        .background(Color.black.opacity(0.4).onTapGesture { withAnimation(spring) { optionsFor = nil } })
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func storeDetailLayer(_ g: StoreGame) -> some View {
        let status: StoreStatus = allGames.contains { $0.titleID.uppercased() == g.id && $0.state == .ready } ? .installed
            : allGames.contains { $0.titleID.uppercased() == g.id && $0.state == .building } ? .building : .available
        return ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { withAnimation(spring) { storeDetail = nil } }
            StoreDetail(game: g, status: status, library: library, builds: builds, actions: actions,
                        close: { withAnimation(spring) { storeDetail = nil } },
                        trailer: { withAnimation(spring) { trailer = g } })
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    private func trailerLayer(_ g: StoreGame) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
                .onTapGesture { withAnimation(spring) { trailer = nil } }
            TrailerSheet(game: g) { withAnimation(spring) { trailer = nil } }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func launchOverlay(_ g: Game) -> some View {
        VStack(spacing: 16) {
            if let icon = g.icon {
                Image(nsImage: icon).resizable().frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            }
            Text("Starting \(g.name)").font(.ui(24, .heavy)).foregroundStyle(.white)
            ProgressView().controlSize(.regular).tint(.white)
        }
        .padding(40)
        .modifier(GlassMod(radius: 32))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func toastView(_ t: Toast) -> some View {
        VStack {
            HStack(spacing: 14) {
                if let id = t.gameID, let g = library.games.first(where: { $0.id == id }), let icon = g.icon {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "bell.fill").foregroundStyle(.white).frame(width: 44, height: 44).background(Circle().fill(.white.opacity(0.12)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.ui(15, .bold)).foregroundStyle(.white)
                    Text(t.subtitle).font(.ui(12, .medium)).foregroundStyle(.white.opacity(0.65))
                }
                if let id = t.gameID, let g = library.games.first(where: { $0.id == id }) {
                    if t.crash {
                        PillButton(title: "Open log", icon: "doc.text") { library.openLog(g) }
                    } else if g.state == .ready {
                        PillButton(title: "Play", icon: "play.fill", prominent: true) { withAnimation { toast = nil }; play(g) }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .modifier(GlassMod(radius: 22))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .padding(.top, 18)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 60)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.ui(34, .heavy)).foregroundStyle(.white)
            Text(detail).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Behaviour

    private func finishSetup() {
        withAnimation(spring) { setup = false; editingFolders = false }
        library.rescan()
        catalog.load()
    }

    private func setUp() {
        focused = true
        DispatchQueue.main.async { styleWindow() }
        if env["NXLIB_DETAIL"] == "1", page == .store {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { storeDetail = catalog.games.last }
        }
        if env["NXLIB_TRAILER"] == "1", page == .store {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { trailer = catalog.games.first { $0.name.contains("Breath") } }
        }
        if let i = Int(env["NXLIB_SELECT"] ?? ""), library.games.indices.contains(i) { selectedID = library.games[i].id }
        if env["NXLIB_PANEL"] == "1" { optionsFor = current?.id }
        wasBuilding = Set(library.games.filter { $0.state == .building }.map(\.id))
        pad.onMove = { move($0) }
        pad.onVertical = { _ in }
        pad.onPage = { switchPage($0) }
        pad.onPlay = { primary() }
        pad.onFolder = { if let g = current { library.reveal(g) } }
        pad.onSettings = { if let g = current { actions.options(g) } }
        pad.onBack = { back() }
        pad.onMenu = { go(.system) }
        if intro {
            Sfx.launch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut(duration: 0.7)) { intro = false } }
        }
        if fullscreenOnStart && !isSnapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let w = NSApp.windows.first(where: { $0.isVisible }), !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            }
        }
    }

    /// A / Return: play the selected game, or on the Store open the banner game's details.
    private func primary() {
        guard storeDetail == nil, trailer == nil else { return }
        if page == .store {
            let f = catalog.featured
            if f.indices.contains(storeFeatured) { Sfx.panel(); withAnimation(spring) { storeDetail = f[storeFeatured] } }
        } else if let g = current { play(g) }
    }

    /// An empty unified toolbar gives the window a taller title area, so macOS draws its close,
    /// minimise and full-screen buttons inset from the corner, centred over the sidebar.
    private func styleWindow() {
        guard !isSnapshot, let w = NSApp.windows.first(where: { $0.contentView != nil && $0.className.contains("SwiftUI") }) ?? NSApp.windows.first else { return }
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        if w.toolbar == nil {
            let tb = NSToolbar(identifier: "nxos")
            tb.showsBaselineSeparator = false
            w.toolbar = tb
        }
        w.toolbarStyle = .unified
    }

    private func go(_ p: Page) {
        guard p != page else { return }
        Sfx.move()
        withAnimation(spring) { page = p; optionsFor = nil }
    }

    private func switchPage(_ d: Int) {
        let tabs = Page.tabs
        let i = tabs.firstIndex(of: page) ?? 0
        go(tabs[(i + d + tabs.count) % tabs.count])
    }

    private func back() {
        if trailer != nil { withAnimation(spring) { trailer = nil } }
        else if storeDetail != nil { withAnimation(spring) { storeDetail = nil } }
        else if optionsFor != nil { withAnimation(spring) { optionsFor = nil } }
        else if searching { withAnimation(spring) { searching = false; query = "" }; focused = true }
        else { go(.home) }
    }

    /// Left / right moves through the games in the order the current page shows them.
    private func move(_ d: Int) {
        guard optionsFor == nil, storeDetail == nil, trailer == nil else { return }
        if page == .store {
            let n = catalog.featured.count
            guard n > 0 else { return }
            Sfx.move()
            withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.6)) { storeFeatured = (storeFeatured + d + n) % n }
            return
        }
        let order: [Game]
        switch page {
        case .home: order = HomePage.popular(games, library)
        case .library, .games: order = games
        default: return
        }
        guard !order.isEmpty else { return }
        let i = order.firstIndex { $0.id == selectedID } ?? -1
        let next = max(0, min(order.count - 1, i + d))
        if order[next].id != selectedID { Sfx.move() }
        withAnimation(spring) { selectedID = order[next].id }
    }

    private func skipBinding(_ g: Game) -> Binding<Bool> {
        Binding(get: { skipMap[g.id] ?? skipWindowDefault },
                set: { v in
                    var d = skipMap; d[g.id] = v
                    if let data = try? JSONSerialization.data(withJSONObject: d) { skipWindowStore = String(decoding: data, as: UTF8.self) }
                })
    }
    private var skipMap: [String: Bool] {
        (try? JSONSerialization.jsonObject(with: Data(skipWindowStore.utf8)) as? [String: Bool]) ?? [:]
    }

    private func play(_ g: Game) {
        guard g.state == .ready, !library.running.contains(g.id), library.launching == nil else {
            if g.state == .building { go(.builds) }
            return
        }
        let skip = skipMap[g.id] ?? skipWindowDefault
        selectedID = g.id
        Sfx.launch()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { library.launching = g.id; optionsFor = nil }
        withAnimation(.easeOut(duration: 0.15)) { flash = 0.3 }
        withAnimation(.easeIn(duration: 0.6).delay(0.15)) { flash = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            library.launch(g, skipWindow: skip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(spring) { library.launching = nil }
                if library.running.contains(g.id) { NSApp.hide(nil) }
            }
        }
    }

    private func noticeFinishedBuilds(_ gs: [Game]) {
        let nowBuilding = Set(gs.filter { $0.state == .building }.map(\.id))
        for id in wasBuilding.subtracting(nowBuilding) {
            if let g = gs.first(where: { $0.id == id && $0.state == .ready }) {
                library.failedStart[g.id] = nil
                show(Toast(title: "\(g.name) is ready", subtitle: "The build finished. Have fun!", gameID: g.id))
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        wasBuilding = nowBuilding
    }

    /// Why a game may have stopped: most often it was built from a version nxnative wasn't brought up on.
    private func crashHint(_ g: Game) -> String {
        if let s = catalog.games.first(where: { $0.id == g.titleID.uppercased() }), let tested = s.tested,
           !tested.hasPrefix(g.version.isEmpty ? "?" : g.version) {
            return "It's built from version \(g.version.isEmpty ? "?" : g.version); nxnative supports update \(tested). Add that update next to the dump and rebuild."
        }
        return "Its log says why."
    }

    private func shortHint(_ g: Game) -> String {
        if let s = catalog.games.first(where: { $0.id == g.titleID.uppercased() }), let tested = s.tested,
           !tested.hasPrefix(g.version.isEmpty ? "?" : g.version) { return "Needs update \(tested)" }
        return "Won't start"
    }

    private func show(_ t: Toast) {
        Sfx.panel()
        withAnimation(spring) { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.crash ? 20 : 8)) { if toast == t { withAnimation(spring) { toast = nil } } }
    }
}

// MARK: - Sidebar

/// The rail on the left: the logo, the pages (search sits second, as on a console), then
/// System, the controller and sound, and the account menu.
struct Sidebar: View {
    @Binding var page: Page
    let searching: Bool
    @Binding var muted: Bool
    let buildingCount: Int
    let padConnected: Bool
    let go: (Page) -> Void
    let search: () -> Void
    @Namespace private var ns
    @State private var pickingAvatar = false
    @AppStorage("avatar") private var avatar = ""

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 24, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [mint, Color(red: 0.42, green: 0.48, blue: 0.95)], startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
                .padding(.top, 58)      // the window's buttons sit above it
                .help("NX OS").accessibilityLabel("NX OS")
            Spacer(minLength: 16)
            VStack(spacing: 6) {
                item(.home)
                railButton("magnifyingglass", "Search", selected: searching, action: search).help("Search (F)")
                ForEach([Page.store, .library, .games, .builds, .stats], id: \.self) { item($0) }
            }
            Spacer(minLength: 16)
            VStack(spacing: 6) {
                item(.system)
                Image(systemName: padConnected ? "gamecontroller.fill" : "gamecontroller")
                    .font(.system(size: 15)).foregroundStyle(padConnected ? mint : Theme.ink2)
                    .frame(width: 52, height: 34)
                    .help(padConnected ? "Controller connected" : "No controller")
                    .accessibilityLabel(padConnected ? "Controller connected" : "No controller")
                Button { muted.toggle(); Sfx.muted = muted } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 14))
                        .foregroundStyle(Theme.ink2).frame(width: 52, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).help("Sound (M)")
                .accessibilityLabel(muted ? "Turn sound on" : "Turn sound off")
                Clock().frame(height: 34)
                Menu {
                    Button("Change Avatar…") { pickingAvatar = true }
                    Divider()
                    Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    Button("Quit NX OS") { NSApp.terminate(nil) }
                } label: { Avatar(size: 38) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(SystemInfo.firstName), account menu")
                .popover(isPresented: $pickingAvatar, arrowEdge: .trailing) { AvatarPicker(selected: $avatar) { pickingAvatar = false } }
            }
            .padding(.bottom, 16)
        }
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        // full height and flush, like a Mac sidebar: the window's buttons sit in its top
        .background(LinearGradient(colors: [Theme.rail.mix(with: .white, by: 0.04), Theme.rail], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
    }

    private func item(_ p: Page) -> some View {
        railButton(page == p ? p.icon : p.outlineIcon, p.title, selected: page == p,
                   badge: p == .builds && buildingCount > 0 ? buildingCount : nil) { go(p) }
            .accessibilityAddTraits(page == p ? .isSelected : [])
    }

    private func railButton(_ icon: String, _ title: String, selected: Bool, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        RailButton(icon: icon, title: title, selected: selected, badge: badge, ns: ns, action: action)
    }
}

struct RailButton: View {
    let icon: String
    let title: String
    let selected: Bool
    let badge: Int?
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
                Text(title).font(.ui(11, selected ? .bold : .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(selected ? mint : hover ? .white : Theme.ink2)
            .frame(width: 66, height: 52)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(mint.opacity(0.13))
                        .matchedGeometryEffect(id: "sel", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text("\(badge)").font(.ui(11, .heavy)).foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17).background(Circle().fill(.orange)).offset(x: -6, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(snappy) { hover = h } }
        .accessibilityLabel(badge.map { "\(title), \($0) building" } ?? title)
    }
}

/// The search field that slides down over the page.
struct SearchBar: View {
    @Binding var query: String
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    let submit: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink2)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain).font(.ui(15, .medium)).foregroundStyle(.white)
                .focused(focus)
                .onSubmit(submit)
                .onExitCommand(perform: close)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Text("Clear").font(.ui(12, .semibold)).foregroundStyle(Theme.ink2)
                }
                .buttonStyle(PressStyle())
            }
            IconButton(icon: "xmark", help: "Close search (Esc)", action: close)
        }
        .padding(.leading, 18).padding(.trailing, 8).frame(height: 48)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(mint.opacity(0.35), lineWidth: 1))
    }
}

struct Clock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { t in
            Text(t.date, format: .dateTime.hour().minute())
                .font(.ui(12, .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - App

@main
enum Main {
    static func main() {
        registerFonts()
        if let out = env["NXLIB_SNAPSHOT"] { snapshot(to: out) } else { NXOSApp.main() }
    }

    /// Renders one frame offscreen, without opening a window.
    @MainActor static func snapshot(to out: String) {
        _ = NSApplication.shared
        let view = OSView().frame(width: CGFloat(Double(env["NXLIB_W"] ?? "") ?? 1440), height: CGFloat(Double(env["NXLIB_H"] ?? "") ?? 900))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { exit(1) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        exit(0)
    }
}

/// Quitting while a build runs would stop it, so it asks first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let folder = BuildQueue.busy else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "\(folder) is still building"
        a.informativeText = "Quitting NX OS stops the build. You can start it again later from Builds, and it continues from where it got to."
        a.addButton(withTitle: "Keep Building")
        a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct NXOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("NX OS") {
            OSView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
