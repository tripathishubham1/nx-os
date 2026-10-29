// NX OS core: the game model, the library scan, saved choices, sound, controller input, cards,
// the backdrop and the per-game settings panel. Games are the nxnative Mac apps in the games
// folder chosen at first launch (Paths): a folder holding "<name>.app" is a game; a "<name>.app.partial" or a
// "*_build" folder without an app is a build in progress, followed through its log.
// Settings follow nxnative's docs/frontends.md: the list is the app's dm/launcher.json, choices
// go to the app's preferences domain as launcher.<env>, and DM_LAUNCHER=0 skips its own window.
import SwiftUI
import AppKit
import GameController
import CoreImage

/// The two folders NX OS works with, chosen on the setup screen and kept in UserDefaults.
enum Paths {
    static let gamesKey = "gamesRoot", nxnativeKey = "nxnativeRoot"
    static var configured: Bool { UserDefaults.standard.string(forKey: gamesKey) != nil }
    static func url(_ key: String, _ fallback: String) -> URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: key) ?? (fallback as NSString).expandingTildeInPath)
    }
    /// nxnative's build script lives here in a usable checkout.
    static func isNxnative(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
    }
}
var gamesRoot: URL { Paths.url(Paths.gamesKey, "~/Games/NX OS") }
let env = ProcessInfo.processInfo.environment
let isSnapshot = env["NXLIB_SNAPSHOT"] != nil
let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
/// Quick, settled motion for hovers and presses.
let snappy = Animation.spring(response: 0.28, dampingFraction: 0.78)

extension String {
    /// Search matching that ignores case and accents ("poke" finds "Pokémon").
    func matches(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// MARK: - Type

/// Registers the bundled Plus Jakarta Sans so `Font.ui` can use it.
func registerFonts() {
    let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts")]
    for d in dirs.compactMap({ $0 }) {
        for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// The OS typeface: Plus Jakarta Sans, falling back to SF Rounded.
    /// Type scale (points): 11 caption · 12 footnote · 13 body · 14 callout · 15 headline ·
    /// 17 title 3 · 20 title 2 · 24 title · 34 large title · 38 display. Use only these.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "Plus Jakarta Sans", size: size) != nil
            ? .custom("Plus Jakarta Sans", size: size).weight(weight)
            : .system(size: size, weight: weight, design: .rounded)
    }
}

/// The navy palette of the reference design.
enum Theme {
    static let desk = Color(red: 0.25, green: 0.36, blue: 0.64)     // around the frame
    static let panel = Color(red: 0.09, green: 0.14, blue: 0.29)    // the frame
    static let rail = Color(red: 0.11, green: 0.17, blue: 0.34)     // sidebar and side panel
    static let card = Color(red: 0.14, green: 0.21, blue: 0.41)     // cards on the panel
    static let ink2 = Color(red: 0.64, green: 0.7, blue: 0.87)      // secondary text and icons
}

extension View {
    /// The reference's raised card: lighter at the top, a hairline highlight, a soft shadow.
    func raised(_ radius: CGFloat, fill: Color = Theme.card, lit: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(LinearGradient(colors: [fill.mix(with: .white, by: lit ? 0.11 : 0.06), fill],
                                                     startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.24 : 0.13), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(lit ? 0.32 : 0.18), radius: lit ? 16 : 10, y: lit ? 9 : 5)
    }
}

/// macOS "Reduce motion": decorative motion stops, autoplay is skipped and moves become fades.
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

extension View {
    /// A tap-to-open view reads as one button to VoiceOver and Full Keyboard Access.
    func tappable(_ label: String, hint: String = "", action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

// MARK: - Model

struct Setting: Identifiable {
    enum Kind { case choice([(String, String)]), toggle(on: String, off: String), range(min: Double, max: Double, step: Double) }
    let id: String          // the env switch, e.g. DM_OPMODE
    let label: String
    let note: String
    let section: String
    let kind: Kind
    let defaultValue: String
    let needs: (String, String)?
    let basic: Bool

    init?(_ d: [String: Any]) {
        guard let envName = d["env"] as? String, let kind = d["kind"] as? String else { return nil }
        id = envName
        label = d["label"] as? String ?? envName
        note = d["note"] as? String ?? ""
        section = d["section"] as? String ?? "Game"
        defaultValue = "\(d["default"] ?? "")"
        basic = (d["level"] as? String) == "basic"
        if let n = d["needs"] as? String, let eq = n.firstIndex(of: "=") {
            needs = (String(n[..<eq]), String(n[n.index(after: eq)...]))
        } else { needs = nil }
        switch kind {
        case "choice":
            let opts = (d["options"] as? [[Any]] ?? []).compactMap { o -> (String, String)? in
                guard o.count >= 2 else { return nil }
                return ("\(o[0])", "\(o[1])")
            }
            self.kind = .choice(opts)
        case "toggle":
            self.kind = .toggle(on: "\(d["on"] ?? "1")", off: "\(d["off"] ?? "0")")
        case "range":
            self.kind = .range(min: (d["min"] as? Double) ?? 0, max: (d["max"] as? Double) ?? 1, step: (d["step"] as? Double) ?? 0.1)
        default:
            return nil
        }
    }
}

struct BuildStatus: Equatable {
    var stage = ""          // "Mac shaders"
    var step = ""           // "compiling"
    var k = 0, n = 0
    var percent: Int?
    var eta: String?
    var detail: String?     // "312 of 19,592 shaders", "4.1 GB of 15 GB"
    var overall: Double { n == 0 ? 0 : (Double(k - 1) + Double(percent ?? 0) / 100) / Double(n) }
}

struct Game: Identifiable, Equatable {
    enum State: Equatable { case ready, building }
    let id: String            // the game folder's path
    let folder: URL
    let app: URL?
    let name: String
    let titleID: String
    let bundleID: String
    let version: String
    let state: State
    let icon: NSImage?
    let accent: Color
    var build: BuildStatus?

    /// The same game while it's being rebuilt: still has its app and art, but can't be started.
    func rebuilding(_ st: BuildStatus) -> Game {
        Game(id: id, folder: folder, app: app, name: name, titleID: titleID, bundleID: bundleID, version: version,
             state: .building, icon: icon, accent: accent, build: st)
    }

    static func == (a: Game, b: Game) -> Bool {
        a.id == b.id && a.app == b.app && a.state == b.state && a.version == b.version && a.build == b.build
    }
}

/// The icon's average color, brightened and saturated so it reads as a glow on black.
func accentColor(of image: NSImage?) -> Color {
    guard let image, let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
          let filter = CIFilter(name: "CIAreaAverage",
                                parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
          let out = filter.outputImage else { return Color(red: 0.9, green: 0.2, blue: 0.3) }
    var px = [UInt8](repeating: 0, count: 4)
    CIContext().render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: h, saturation: min(1, max(0.55, s * 1.6)), brightness: max(0.85, b))
}

private func modified(_ u: URL) -> Date {
    (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

/// The newest progress of the build of the game folder `dir`, from the build logs in the games folder.
func readBuildStatus(dir: String) -> BuildStatus? {
    let logs = ((try? FileManager.default.contentsOfDirectory(at: gamesRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        .filter { $0.pathExtension == "log" }
        .sorted { modified($0) > modified($1) }
    for log in logs {
        guard let h = try? FileHandle(forReadingFrom: log) else { continue }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        try? h.close()
        let markers = ["===== building \(dir) =====", "/Games/\(dir)/"]
        guard let start = markers.compactMap({ text.range(of: $0, options: .backwards)?.lowerBound }).max() else { continue }
        var tail = text[start...]
        // a later "===== building" for another game ends this one's section
        if let next = tail.dropFirst(10).range(of: "===== building ") { tail = tail[..<next.lowerBound] }
        if tail.contains("EXIT \(dir):") { return nil }
        var st = BuildStatus()
        for line in tail.split(separator: "\n").reversed() {
            guard let m = line.firstMatch(of: #/\[(\d+)/(\d+)\] ([^·…✓✗(:]+?)(?: · ([^:…]+?))?(?: …|:|$| \()/#) else { continue }
            st.k = Int(m.1) ?? 0; st.n = Int(m.2) ?? 0
            st.stage = String(m.3).trimmingCharacters(in: .whitespaces)
            st.step = m.4.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if let p = line.firstMatch(of: #/(\d+)%/#) { st.percent = Int(p.1) }
            if let e = line.firstMatch(of: #/ETA ([\d:]+)/#) { st.eta = String(e.1) }
            if line.contains("✓") { st.percent = 100 }
            return st
        }
        return st
    }
    return nil
}

final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var driveMounted = true
    @Published var running: Set<String> = []
    @Published var launching: String?
    /// A game that quit with an error soon after starting: (game ID, exit code).
    @Published var crashed: (id: String, code: Int32)?
    /// Games whose last start failed, with a short reason ("needs update 1.9.0"); cleared by a good run or a rebuild.
    @Published var failedStart: [String: String] = (UserDefaults.standard.dictionary(forKey: "failedStart") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(failedStart, forKey: "failedStart") }
    }
    @Published var lastPlayed: [String: Date] = (UserDefaults.standard.dictionary(forKey: "lastPlayed") as? [String: Date]) ?? [:]
    @Published var playTime: [String: Double] = (UserDefaults.standard.dictionary(forKey: "playTime") as? [String: Double]) ?? [:]
    /// Seconds played per day ("2026-10-29"), for the play-time trend.
    @Published var daily: [String: Double] = (UserDefaults.standard.dictionary(forKey: "dailyPlay") as? [String: Double]) ?? [:]
    static let dayKey: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private var art: [String: (NSImage, Color)] = [:]
    private var timer: Timer?
    private var started: [String: Date] = [:]
    private var processes: [String: Process] = [:]

    init() {
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.rescan() }
    }

    func rescan() {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gamesRoot.path, isDirectory: &isDir), isDir.boolValue else {
            if driveMounted || !games.isEmpty { driveMounted = false; games = [] }
            return
        }
        driveMounted = true
        let folders = (try? fm.contentsOfDirectory(at: gamesRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        // builds running right now (this NX OS or another), by game folder: a rebuild keeps its old app
        let running = Set(shell("/bin/ps", ["-axo", "command"]).split(separator: "\n").compactMap { line -> String? in
            // an iPhone build leaves the Mac app playable
            guard let r = line.range(of: "build_ipa_from_nsp.py "), !line.contains("--platform ios") else { return nil }
            let rest = line[r.upperBound...]
            let path = rest.range(of: " -")
                .map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            return URL(fileURLWithPath: path).lastPathComponent
        })
        var found: [Game] = []
        for folder in folders {
            let name = folder.lastPathComponent
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !name.hasPrefix("_"), !name.hasPrefix(".") else { continue }
            let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if let appName = items.first(where: { $0.hasSuffix(".app") && !$0.hasPrefix("._") }) {
                let g = readApp(folder: folder, app: folder.appendingPathComponent(appName))
                found.append(running.contains(name) ? g.rebuilding(readBuildStatus(dir: name) ?? BuildStatus(stage: "Starting", step: "", k: 1, n: 8)) : g)
            } else if items.contains(where: { $0.hasSuffix(".app.partial") || $0.hasSuffix("_build") }) {
                let tid = items.first(where: { $0.hasSuffix("_build") }).map { String($0.dropLast(6)) } ?? ""
                found.append(Game(id: folder.path, folder: folder, app: nil, name: name, titleID: tid, bundleID: "",
                                  version: "", state: .building, icon: nil, accent: .orange,
                                  build: readBuildStatus(dir: name)))
            }
        }
        found.sort { ($0.state == .ready ? 0 : 1, $0.name) < ($1.state == .ready ? 0 : 1, $1.name) }
        if found != games { games = found }
    }

    private func readApp(folder: URL, app: URL) -> Game {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let iconFile = (info["CFBundleIconFile"] as? String) ?? "AppIcon"
        let iconURL = app.appendingPathComponent("Contents/Resources/\(iconFile).icns")
        if art[iconURL.path] == nil, let img = NSImage(contentsOf: iconURL) {
            art[iconURL.path] = (img, accentColor(of: img))
        }
        let a = art[iconURL.path]
        return Game(id: folder.path, folder: folder, app: app, name: name,
                    titleID: (info["DMTitleID"] as? String) ?? "",
                    bundleID: (info["CFBundleIdentifier"] as? String) ?? "",
                    version: (info["CFBundleShortVersionString"] as? String) ?? "",
                    state: .ready, icon: a?.0, accent: a?.1 ?? .red)
    }

    func settings(for game: Game) -> [Setting] {
        guard let app = game.app,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/dm/launcher.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["settings"] as? [[String: Any]] else { return [] }
        return rows.compactMap(Setting.init)
    }

    /// Starts the app's executable directly: Launch Services gives up (-10810) on these
    /// ad-hoc signed, multi-GB bundles on the exFAT drive before its assessment finishes.
    func launch(_ game: Game, skipWindow: Bool) {
        guard let app = game.app, !running.contains(game.id) else { return }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let exe = app.appendingPathComponent("Contents/MacOS/\((info["CFBundleExecutable"] as? String) ?? "nxnative")")
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = app.appendingPathComponent("Contents/MacOS")
        var e = ProcessInfo.processInfo.environment
        if skipWindow { e["DM_LAUNCHER"] = "0" }
        p.environment = e
        let previous = lastPlayed[game.id]
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let ran = self.started[game.id].map { Date().timeIntervalSince($0) } ?? 0
                if proc.terminationStatus != 0 && ran < 60 {
                    // it never really started: no play time, and it stays out of "Continue"
                    self.lastPlayed[game.id] = previous
                    UserDefaults.standard.set(self.lastPlayed, forKey: "lastPlayed")
                    self.crashed = (game.id, proc.terminationStatus)
                } else if ran > 0 {
                    self.failedStart[game.id] = nil
                    self.playTime[game.id, default: 0] += ran
                    UserDefaults.standard.set(self.playTime, forKey: "playTime")
                    self.daily[Library.dayKey.string(from: Date()), default: 0] += ran
                    UserDefaults.standard.set(self.daily, forKey: "dailyPlay")
                }
                self.running.remove(game.id); self.processes[game.id] = nil; self.started[game.id] = nil
                if self.running.isEmpty { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true) }
            }
        }
        do {
            try p.run()
            processes[game.id] = p
            running.insert(game.id)
            started[game.id] = Date()
            lastPlayed[game.id] = Date()
            UserDefaults.standard.set(lastPlayed, forKey: "lastPlayed")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't start \(game.name)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Deletes the whole game folder (app, dumps, build files) and, if asked, its save
    /// data on the Mac. Asks first; refuses while the game runs or builds.
    func delete(_ game: Game, done: @escaping (String) -> Void) {
        guard !running.contains(game.id) else { done("Quit \(game.name) before deleting it."); return }
        guard game.state == .ready else { done("Stop the build of \(game.name) before deleting it."); return }
        let saves = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative/\(game.titleID)")
        let size = (try? FileManager.default.subpathsOfDirectory(atPath: game.folder.path))?.reduce(Int64(0)) { sum, p in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: game.folder.appendingPathComponent(p).path)[.size] as? Int) ?? 0)
        } ?? 0
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Delete \(game.name)?"
        a.informativeText = "This permanently deletes its folder on \(SystemInfo.driveName): the built app, your dump files and any build files"
            + " (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). It can't be undone."
        let keep = NSButton(checkboxWithTitle: "Also delete its save data on this Mac", target: nil, action: nil)
        keep.state = .off
        if FileManager.default.fileExists(atPath: saves.path) { a.accessoryView = keep }
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let alsoSaves = keep.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try FileManager.default.removeItem(at: game.folder) } catch { err = error.localizedDescription }
            if alsoSaves { try? FileManager.default.removeItem(at: saves) }
            for log in ((try? FileManager.default.contentsOfDirectory(at: gamesRoot, includingPropertiesForKeys: nil)) ?? [])
                where log.lastPathComponent == "nxnative-\(game.folder.lastPathComponent).log" { try? FileManager.default.removeItem(at: log) }
            DispatchQueue.main.async {
                self.playTime[game.id] = nil; self.lastPlayed[game.id] = nil; self.failedStart[game.id] = nil
                UserDefaults.standard.set(self.playTime, forKey: "playTime")
                UserDefaults.standard.set(self.lastPlayed, forKey: "lastPlayed")
                self.rescan()
                done(err.map { "Couldn't delete \(game.name) completely: \($0)" }
                     ?? "\(game.name) was deleted" + (alsoSaves ? ", with its saves." : ". Its saves are kept."))
            }
        }
    }

    func reveal(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([game.app ?? game.folder])
    }

    func openLog(_ game: Game) {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nxnative/\(game.titleID).log")
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
    }
}

// MARK: - Saved choices (the game app's own preferences domain, docs/frontends.md)

enum Choices {
    static func get(_ s: Setting, bundle: String) -> String {
        (CFPreferencesCopyAppValue("launcher.\(s.id)" as CFString, bundle as CFString) as? String) ?? s.defaultValue
    }
    /// Keeps only choices that differ from the tested default, as the game's own window does.
    static func set(_ s: Setting, _ value: String, bundle: String) {
        let v: CFPropertyList? = value == s.defaultValue ? nil : value as CFString
        CFPreferencesSetAppValue("launcher.\(s.id)" as CFString, v, bundle as CFString)
        CFPreferencesAppSynchronize(bundle as CFString)
    }
    static func reset(_ settings: [Setting], bundle: String) {
        for s in settings { CFPreferencesSetAppValue("launcher.\(s.id)" as CFString, nil, bundle as CFString) }
        CFPreferencesAppSynchronize(bundle as CFString)
    }
}

// MARK: - Sound

enum Sfx {
    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "muted") }
        set { UserDefaults.standard.set(newValue, forKey: "muted") }
    }
    private static let tick: NSSound? = { let s = NSSound(named: "Tink"); s?.volume = 0.18; return s }()
    private static let open: NSSound? = { let s = NSSound(named: "Pop"); s?.volume = 0.35; return s }()
    private static let start: NSSound? = { let s = NSSound(named: "Glass"); s?.volume = 0.5; return s }()
    static func move() { play(tick) }
    static func panel() { play(open) }
    static func launch() { play(start) }
    private static func play(_ s: NSSound?) {
        guard !muted, !isSnapshot, let s else { return }
        s.stop(); s.play()
    }
}

// MARK: - Controller input

final class Pad: ObservableObject {
    @Published var connected = false
    var onMove: ((Int) -> Void)?
    var onPlay: (() -> Void)?
    var onFolder: (() -> Void)?
    var onSettings: (() -> Void)?
    var onBack: (() -> Void)?
    var onMenu: (() -> Void)?
    var onPage: ((Int) -> Void)?
    var onVertical: ((Int) -> Void)?
    private var lastMove = Date.distantPast

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
            self?.connected = !GCController.controllers().isEmpty
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.connected = !GCController.controllers().isEmpty
        }
        GCController.controllers().forEach(attach)
        connected = !GCController.controllers().isEmpty
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, on in if on { self?.move(-1) } }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, on in if on { self?.move(1) } }
        pad.dpad.up.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fireInt(self?.onVertical, -1) } }
        pad.dpad.down.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fireInt(self?.onVertical, 1) } }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fireInt(self?.onPage, -1) } }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fireInt(self?.onPage, 1) } }
        pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, v in
            if abs(v) > 0.6 { self?.move(v > 0 ? 1 : -1, repeatDelay: 0.28) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fire(self?.onPlay) } }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fire(self?.onBack) } }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fire(self?.onFolder) } }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fire(self?.onSettings) } }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, on in if on { self?.fire(self?.onMenu) } }
    }

    private func fire(_ f: (() -> Void)?) { DispatchQueue.main.async { f?() } }
    private func fireInt(_ f: ((Int) -> Void)?, _ v: Int) { DispatchQueue.main.async { f?(v) } }

    private func move(_ d: Int, repeatDelay: TimeInterval = 0) {
        let now = Date()
        guard now.timeIntervalSince(lastMove) >= repeatDelay else { return }
        lastMove = now
        DispatchQueue.main.async { self.onMove?(d) }
    }
}

// MARK: - Cards

struct CoverCard: View {
    let game: Game
    let isRunning: Bool
    let isSelected: Bool
    let size: CGFloat
    var glare: UnitPoint? = nil

    private var corner: CGFloat { size * 0.11 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
            if let icon = game.icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                BuildingFace(size: size, status: game.build)
            }
            // glass sheen
            LinearGradient(stops: [.init(color: .white.opacity(0.3), location: 0),
                                   .init(color: .white.opacity(0.04), location: 0.42),
                                   .init(color: .clear, location: 0.43)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .blendMode(.screen)
            // a light that follows the pointer
            if let glare {
                RadialGradient(colors: [.white.opacity(0.14), .clear], center: glare, startRadius: 0, endRadius: size * 0.6)
                    .blendMode(.screen)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    isRunning ? AnyShapeStyle(Color.green)
                    : isSelected ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.9), game.accent.opacity(0.6)],
                                                                startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.white.opacity(0.12)),
                    lineWidth: isRunning || isSelected ? 3 : 1)
        )
    }
}

/// A card for a game that is still being built: animated stripes, a progress ring and the stage.
struct BuildingFace: View {
    let size: CGFloat
    let status: BuildStatus?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { t in
            let phase = CGFloat(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2)
            ZStack {
                Canvas { ctx, sz in
                    let w: CGFloat = 26
                    var x = -sz.height + phase * w * 2
                    while x < sz.width {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: sz.height)); p.addLine(to: CGPoint(x: x + sz.height, y: 0))
                        p.addLine(to: CGPoint(x: x + sz.height + w, y: 0)); p.addLine(to: CGPoint(x: x + w, y: sz.height))
                        ctx.fill(p, with: .color(.orange.opacity(0.07)))
                        x += w * 2
                    }
                }
                buildInfo
            }
        }
    }

    private var buildInfo: some View {
        let overall = status?.overall ?? 0
        return VStack(spacing: size * 0.045) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: size * 0.03)
                Circle().trim(from: 0, to: max(0.02, overall))
                    .stroke(LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(overall * 100))%")
                        .font(.ui(size * 0.11, .heavy)).monospacedDigit()
                        .foregroundStyle(.white)
                    Image(systemName: "hammer.fill").font(.system(size: size * 0.05)).foregroundStyle(.orange)
                }
            }
            .frame(width: size * 0.42, height: size * 0.42)
            Text("BUILDING").font(.ui(size * 0.055, .heavy))
                .tracking(3).foregroundStyle(.white.opacity(0.8))
            if let s = status, s.n > 0 {
                Text("Step \(s.k)/\(s.n) · \(s.stage)")
                    .font(.ui(size * 0.042, .semibold))
                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .padding(size * 0.08)
    }
}

/// One card in the cover flow, turned and pushed back by its distance from the center.
struct CarouselItem: View {
    let game: Game
    let isRunning: Bool
    let offset: CGFloat
    let isCenter: Bool
    let isLaunching: Bool
    let card: CGFloat
    let spacing: CGFloat
    @State private var float = false
    @State private var hover: CGPoint? = nil   // pointer position in the card, 0...1

    private var dist: CGFloat { abs(offset) }
    private var angle: Double { Double(max(-62, min(62, -offset * 55))) }
    private var scale: CGFloat { isLaunching ? 1.18 : isCenter ? 1.0 : max(0.6, 0.82 - dist * 0.06) }
    private var x: CGFloat {
        let side: CGFloat = offset == 0 ? 0 : (offset > 0 ? 1 : -1)
        return offset * spacing + side * card * 0.26
    }
    private var fade: Double { dist > 4.5 ? 0 : (1 - Double(max(0, dist - 2.5)) * 0.45) }
    private var tiltX: Double { isCenter ? Double(((hover?.y ?? 0.5) - 0.5) * -16) : 0 }
    private var tiltY: Double { isCenter ? Double(((hover?.x ?? 0.5) - 0.5) * 18) : 0 }
    private var glare: UnitPoint? { isCenter ? hover.map { UnitPoint(x: $0.x, y: $0.y) } : nil }

    var body: some View {
        VStack(spacing: 6) {
            front
            reflection
        }
        .brightness(isCenter ? 0 : -0.18)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .scaleEffect(scale)
        .offset(x: x)
        .opacity(fade)
        .zIndex(-Double(dist))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { float = true }
        }
    }

    private var front: some View {
        CoverCard(game: game, isRunning: isRunning, isSelected: isCenter, size: card, glare: glare)
            .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(isCenter ? 0.5 : 0.4),
                    radius: isCenter ? 22 : 14, y: isCenter ? 14 : 10)
            .offset(y: isCenter && float ? -7 : 0)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): withAnimation(.easeOut(duration: 0.12)) { hover = CGPoint(x: p.x / card, y: p.y / card) }
                case .ended: withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { hover = nil }
                }
            }
    }

    // mirrored reflection on the floor
    private var reflection: some View {
        CoverCard(game: game, isRunning: false, isSelected: false, size: card)
            .scaleEffect(x: 1, y: -1)
            .frame(height: card * 0.32, alignment: .top)
            .clipped()
            .mask(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Backdrop

/// The desk around the frame: the reference's flat periwinkle blue, with a faint glow of the
/// selected game's colour.
/// The app's background: the navy panel, with a faint glow of the selected game's colour.
struct Backdrop: View {
    let game: Game?
    var body: some View {
        ZStack {
            Theme.panel
            if let accent = game?.accent {
                RadialGradient(colors: [accent.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: game?.id)
        .ignoresSafeArea()
    }
}

// MARK: - Chrome

struct GlassMod: ViewModifier {
    var radius: CGFloat? = nil
    func body(content: Content) -> some View {
        Group {
            if let radius {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct ButtonHint: View {
    let glyph: String
    let label: String
    var symbol: String? = nil       // an SF Symbol instead of a letter
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .heavy)) }
                else { Text(glyph).font(.ui(12, .heavy)) }
            }
            .foregroundStyle(.black)
            .frame(minWidth: 22, minHeight: 22).padding(.horizontal, glyph.count > 1 ? 5 : 0)
            .background(.white.opacity(0.9), in: Capsule())
            Text(label).font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

func formatPlayTime(_ s: Double) -> String {
    let m = Int(s / 60)
    if m < 1 { return "under a minute" }
    if m < 60 { return "\(m) min" }
    return "\(m / 60)h \(m % 60)m"
}

// MARK: - Settings panel

struct SettingsPanel: View {
    let game: Game
    let settings: [Setting]
    @Binding var skipWindow: Bool
    let close: () -> Void
    @State private var values: [String: String] = [:]

    private var sections: [String] {
        var seen: [String] = []
        for s in settings where !seen.contains(s.section) { seen.append(s.section) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(22)
            Divider().overlay(.white.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Library") {
                        row("Skip the game's settings window") {
                            Toggle("Skip the game's settings window", isOn: $skipWindow).toggleStyle(.switch).tint(game.accent).labelsHidden()
                        }
                    }
                    ForEach(sections, id: \.self) { name in
                        section(name) {
                            ForEach(settings.filter { $0.section == name && visible($0) }) { s in
                                settingRow(s)
                            }
                        }
                    }
                    resetButton
                }
                .padding(22)
            }
        }
        .frame(width: 430)
        .frame(maxHeight: .infinity)
        .modifier(GlassMod(radius: 26))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = game.icon {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.ui(20, .heavy)).foregroundStyle(.white)
                Text(game.name).font(.ui(13, .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            IconButton(icon: "xmark", help: "Close settings", action: close)
        }
    }

    private var resetButton: some View {
        Button {
            Choices.reset(settings, bundle: game.bundleID); load()
        } label: {
            Label("Reset to tested defaults", systemImage: "arrow.counterclockwise")
                .font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14).padding(.vertical, 8).background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        var v: [String: String] = [:]
        for s in settings { v[s.id] = Choices.get(s, bundle: game.bundleID) }
        values = v
    }

    private func visible(_ s: Setting) -> Bool {
        guard let (k, want) = s.needs, settings.contains(where: { $0.id == k }) else { return true }
        return values[k] == want
    }

    private func binding(_ s: Setting) -> Binding<String> {
        Binding(get: { values[s.id] ?? s.defaultValue },
                set: { values[s.id] = $0; Choices.set(s, $0, bundle: game.bundleID) })
    }

    @ViewBuilder private func settingRow(_ s: Setting) -> some View {
        switch s.kind {
        case .choice(let opts): choiceRow(s, opts)
        case .toggle(let on, let off): toggleRow(s, on: on, off: off)
        case .range(let lo, let hi, let step): rangeRow(s, lo: lo, hi: hi, step: step)
        }
    }

    private func choiceRow(_ s: Setting, _ opts: [(String, String)]) -> some View {
        let b = binding(s)
        return row(s.label, note: s.note) {
            if opts.count <= 3 {
                Picker(s.label, selection: b) { ForEach(opts, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
            } else {
                Picker(s.label, selection: b) { ForEach(opts, id: \.0) { Text($0.1).tag($0.0) } }
                    .labelsHidden().frame(maxWidth: 200)
            }
        }
    }

    private func toggleRow(_ s: Setting, on: String, off: String) -> some View {
        let b = binding(s)
        return row(s.label, note: s.note) {
            Toggle(s.label, isOn: Binding(get: { b.wrappedValue == on }, set: { b.wrappedValue = $0 ? on : off }))
                .toggleStyle(.switch).tint(game.accent).labelsHidden()
        }
    }

    private func rangeRow(_ s: Setting, lo: Double, hi: Double, step: Double) -> some View {
        let b = binding(s)
        let fmt = step < 0.1 ? "%.2f" : "%.1f"
        let d = Binding(get: { Double(b.wrappedValue) ?? lo }, set: { b.wrappedValue = String(format: fmt, $0) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.label).font(.ui(14, .semibold)).foregroundStyle(.white).help(s.note)
                Spacer()
                Text(String(format: fmt, d.wrappedValue))
                    .font(.ui(13, .bold)).monospacedDigit()
                    .foregroundStyle(game.accent)
            }
            Slider(value: d, in: lo...hi, step: step).tint(game.accent)
                .accessibilityLabel(s.label).accessibilityValue(String(format: fmt, d.wrappedValue))
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased()).font(.ui(11, .heavy)).tracking(1.8)
                .foregroundStyle(game.accent.opacity(0.9))
            content()
        }
    }

    private func row<C: View>(_ label: String, note: String = "", @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(.ui(14, .semibold)).foregroundStyle(.white).help(note)
            Spacer(minLength: 8)
            control()
        }
    }
}

// MARK: - Grid

struct GridCell: View {
    let game: Game
    let isRunning: Bool
    let isSelected: Bool
    let hovered: Bool

    var body: some View {
        VStack(spacing: 12) {
            CoverCard(game: game, isRunning: isRunning, isSelected: isSelected, size: 190)
                .shadow(color: .black.opacity(hovered || isSelected ? 0.5 : 0.4),
                        radius: hovered ? 18 : 12, y: 10)
                .scaleEffect(hovered ? 1.06 : 1)
                .rotation3DEffect(.degrees(hovered ? 6 : 0), axis: (x: 1, y: -1, z: 0))
            Text(game.name).font(.ui(14, .bold)).foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - Intro

struct Intro: View {
    @State private var phase = 0.0
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(RadialGradient(colors: [mint.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 140))
                        .frame(width: 280, height: 280).scaleEffect(0.6 + phase * 0.6).opacity(phase)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.ui(84, .bold))
                        .foregroundStyle(LinearGradient(colors: [mint, Color(red: 0.42, green: 0.48, blue: 0.95)], startPoint: .top, endPoint: .bottom))
                        .scaleEffect(0.5 + phase * 0.5)
                        .rotation3DEffect(.degrees((1 - phase) * 90), axis: (x: 0, y: 1, z: 0))
                }
                Text("NX OS").font(.ui(34, .heavy)).tracking(10 * phase + 2)
                    .foregroundStyle(.white).opacity(phase)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) { phase = 1 } }
    }
}

