// Services behind the OS pages: game categories, the build queue that installs and builds new
// games with nxnative, and system information.
import SwiftUI
import AppKit

var nxnativeRoot: URL { Paths.url(Paths.nxnativeKey, "~/nxnative") }

// MARK: - Catalog

/// Categories and taglines for the games nxnative supports; other games simply have none.
enum Catalog {
    private static let genres: [String: [String]] = [
        "01008DB008C2C000": ["Pokémon", "RPG"],                       // Shield
        "0100ABF008968000": ["Pokémon", "RPG"],                       // Sword
        "0100F43008C44000": ["Pokémon", "RPG", "Action"],             // Legends: Z-A
        "01001F5010DFA000": ["Pokémon", "RPG", "Open World"],         // Legends: Arceus
        "0100A3D008C5C000": ["Pokémon", "RPG", "Open World"],         // Scarlet
        "0100000011D90000": ["Pokémon", "RPG"],                       // Brilliant Diamond
        "01007EF00011E000": ["Adventure", "Action", "Open World"],     // Breath of the Wild
        "0100F2C0115B6000": ["Adventure", "Action", "Open World"],     // Tears of the Kingdom
        "01006BB00C6F0000": ["Adventure"],                            // Link's Awakening
        "0100000000010000": ["Platformer", "Adventure"],              // Super Mario Odyssey
        "010015100B514000": ["Platformer"],                           // Super Mario Bros. Wonder
        "0100152000022000": ["Racing"],                               // Mario Kart 8 Deluxe
        "01006A800016E000": ["Fighting"],                             // Super Smash Bros. Ultimate
        "01006F8002326000": ["Life Sim"],                             // Animal Crossing: New Horizons
    ]
    private static let taglines: [String: String] = [
        "01008DB008C2C000": "Become the Champion of the Galar region",
        "0100ABF008968000": "Become the Champion of the Galar region",
        "0100F43008C44000": "Lumiose City is changing. Be part of its story",
        "01007EF00011E000": "Step into a world of discovery in Hyrule",
        "0100F2C0115B6000": "Take to the skies above Hyrule",
        "01001F5010DFA000": "Explore the ancient Hisui region",
        "0100A3D008C5C000": "Set out on an open-world adventure in Paldea",
    ]
    private static let icons: [String: String] = [
        "Trending": "flame.fill", "Recent": "clock.fill", "All": "square.grid.2x2.fill",
        "Pokémon": "sparkles", "RPG": "shield.lefthalf.filled", "Adventure": "map.fill",
        "Action": "bolt.fill", "Open World": "globe.americas.fill", "Platformer": "figure.run",
        "Racing": "flag.checkered", "Fighting": "figure.boxing", "Life Sim": "leaf.fill",
        "Building": "hammer.fill",
    ]

    static func genres(of g: Game) -> [String] { genres[g.titleID.uppercased()] ?? guessGenres(g.name) }

    /// Games added later that the table above doesn't know get genres from words in their name,
    /// so they still land in the Home chips and the taste chart.
    private static let keywords: [(String, [String])] = [
        ("Pokémon", ["Pokémon", "RPG"]), ("Zelda", ["Adventure", "Action"]), ("Mario Kart", ["Racing"]),
        ("Mario Party", ["Party"]), ("Mario", ["Platformer"]), ("Kirby", ["Platformer"]), ("Donkey Kong", ["Platformer"]),
        ("Metroid", ["Action", "Adventure"]), ("Fire Emblem", ["Strategy", "RPG"]), ("Xenoblade", ["RPG", "Open World"]),
        ("Smash", ["Fighting"]), ("Splatoon", ["Shooter"]), ("Animal Crossing", ["Life Sim"]), ("Pikmin", ["Strategy"]),
        ("Souls", ["Action", "RPG"]), ("Streets of Rage", ["Action"]), ("SteamWorld", ["Action", "Adventure"]),
        ("Subnautica", ["Survival", "Open World"]), ("Persona", ["RPG"]), ("Final Fantasy", ["RPG"]), ("Dragon Quest", ["RPG"]),
        ("Baba", ["Puzzle"]), ("Tetris", ["Puzzle"]), ("Racing", ["Racing"]), ("Kart", ["Racing"]),
    ]
    private static func guessGenres(_ name: String) -> [String] {
        for (word, g) in keywords where name.matches(word) { return g }
        return ["Other"]
    }
    static func tagline(of g: Game) -> String? { taglines[g.titleID.uppercased()] }
    static func icon(_ category: String) -> String { icons[category] ?? "tag.fill" }

    /// The chips to show for a library: the fixed ones, then the categories its games have.
    static func chips(for games: [Game]) -> [String] {
        var out = ["Trending", "Recent", "All"]
        for g in games { for c in genres(of: g) where !out.contains(c) { out.append(c) } }
        if games.contains(where: { $0.state == .building }) { out.append("Building") }
        return out
    }

    static func filter(_ games: [Game], chip: String, playTime: [String: Double], lastPlayed: [String: Date]) -> [Game] {
        switch chip {
        case "Trending":
            return games.sorted { (playTime[$0.id] ?? -1, $0.state == .ready ? 1 : 0) > (playTime[$1.id] ?? -1, $1.state == .ready ? 1 : 0) }
        case "Recent":
            return games.filter { lastPlayed[$0.id] != nil }.sorted { lastPlayed[$0.id]! > lastPlayed[$1.id]! }
        case "All":
            return games
        case "Building":
            return games.filter { $0.state == .building }
        default:
            return games.filter { genres(of: $0).contains(chip) }
        }
    }
}

// MARK: - Build queue

/// Installs NSP / XCI files into their own game folders and builds them one at a time with
/// nxnative's NSP script. Each build writes <games folder>/nxnative-<folder>.log, framed by
/// "===== building <folder> =====" and "EXIT <folder>: <code>", which the library reads for progress.
final class BuildQueue: ObservableObject {
    @Published var queue: [String] = []
    @Published var active: String? { didSet { Self.busy = active } }
    /// The folder being built, for the quit check (the build reads its progress through NX OS).
    static var busy: String?
    @Published var message: String?
    @Published var updating = false
    private var stopping = false
    private var proc: Process?
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.startNext() }
    }

    var keysPath: String? { Self.findKeys() }

    static func findKeys() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.switch/prod.keys", "\(home)/Library/Application Support/Ryujinx/system/prod.keys"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func titleID(in name: String) -> String? {
        name.firstMatch(of: #/\[([0-9A-Fa-f]{16})\]/#).map { String($0.1).uppercased() }
    }

    static func cleanName(_ raw: String) -> String {
        var s = raw.replacing(#/\[[^\]]*\]|\([^)]*\)/#, with: "")
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacing(#/\s+v\d+(\.\d+)*\s*$/#, with: "")
        s = s.replacing(#/\s{2,}/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
    }

    /// The folder that already holds files of this title (base game, update or DLC share the first 13 digits).
    private static func folder(forTitle tid: String) -> String? {
        let fm = FileManager.default
        let prefix = String(tid.prefix(13))
        for dir in (try? fm.contentsOfDirectory(atPath: gamesRoot.path)) ?? [] where !dir.hasPrefix(".") && !dir.hasPrefix("_") {
            let files = (try? fm.contentsOfDirectory(atPath: gamesRoot.appendingPathComponent(dir).path)) ?? []
            if files.contains(where: { titleID(in: $0)?.hasPrefix(prefix) == true }) || files.contains(where: { $0.hasPrefix(tid) && $0.hasSuffix("_build") }) {
                return dir
            }
        }
        return nil
    }

    /// Store installs: the player picked a dump for a known title, so files missing the title ID
    /// in their name get it added, and new games go in a folder named after the Store title.
    func install(_ files: [URL], titleID: String, name: String, done: @escaping (String?) -> Void) {
        let tagged = files.map { f -> URL in
            guard Self.titleID(in: f.lastPathComponent) == nil else { return f }
            // updates and DLC have their own IDs; only the base game is named for the Store title
            return f.deletingLastPathComponent().appendingPathComponent("\(f.deletingPathExtension().lastPathComponent) [\(titleID)].\(f.pathExtension)")
        }
        install(zip(files, tagged).map { $0 }, folderName: Self.cleanName(name), done: done)
    }

    func install(_ files: [URL], done: @escaping (String?) -> Void) {
        install(files.map { ($0, $0) }, folderName: nil, done: done)
    }

    /// `files` pairs each source with the name it should have on the T7.
    private func install(_ files: [(URL, URL)], folderName: String?, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var dirs: [String] = []
            var problems: [String] = []
            for (f, named) in files {
                let ext = f.pathExtension.lowercased()
                guard ["nsp", "xci", "nsz", "xcz"].contains(ext) else { problems.append("\(f.lastPathComponent) is not a game file"); continue }
                let tid = Self.titleID(in: named.lastPathComponent)
                if ["xci", "xcz"].contains(ext), tid == nil {
                    problems.append("\(f.lastPathComponent): add the title ID to its name, like “Game [0100…]”.xci")
                    continue
                }
                let name = tid.flatMap(Self.folder(forTitle:)) ?? folderName ?? Self.cleanName(f.deletingPathExtension().lastPathComponent)
                let dir = gamesRoot.appendingPathComponent(name)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(named.lastPathComponent)
                    if SystemInfo.sameVolume(f, gamesRoot) { try fm.moveItem(at: f, to: dest) } else { try fm.copyItem(at: f, to: dest) }
                    if !dirs.contains(name) { dirs.append(name) }
                } catch {
                    problems.append("\(f.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                for d in dirs where !self.queue.contains(d) && self.active != d { self.queue.append(d) }
                self.startNext()
                done(problems.isEmpty ? nil : problems.joined(separator: "\n"))
            }
        }
    }

    func rebuild(_ folder: String) {
        guard !queue.contains(folder), active != folder else { return }
        queue.append(folder)
        startNext()
    }

    func cancelQueued(_ folder: String) { queue.removeAll { $0 == folder } }

    /// Stops the running build. Its folder keeps what was done, so the next build picks up from there.
    func stop(_ folder: String) {
        guard active == folder else { return }
        stopping = true
        _ = shell("/usr/bin/pkill", ["-INT", "-f", "build_ipa_from_nsp.py \(gamesRoot.appendingPathComponent(folder).path)"])
        proc?.interrupt()
    }

    /// Another build (started outside NX OS) is still running.
    private func externalBuildRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "build_ipa_from_nsp.py"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Live progress of the running build, from nxnative's `--progress json` stream (≤ 0.5 s apart).
    @Published var live: [String: BuildStatus] = [:]
    private var lastLogged = Date.distantPast

    func startNext() {
        guard active == nil, let next = queue.first else { return }
        guard let keys = keysPath else { message = "No prod.keys found: put yours in ~/.switch/prod.keys"; return }
        if externalBuildRunning() { return }
        queue.removeFirst()
        active = next
        live[next] = BuildStatus(stage: "Starting", step: "", k: 1, n: 8)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var e = ProcessInfo.processInfo.environment
        e["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        e["DOTNET_ROOT"] = "\(home)/.dotnet"
        e["PATH"] = "\(home)/.dotnet:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["PYTHONUNBUFFERED"] = "1"
        let logURL = gamesRoot.appendingPathComponent("nxnative-\(next).log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        func write(_ line: String) { log?.write(Data((line + "\n").utf8)) }
        write("===== building \(next) =====")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.currentDirectoryURL = nxnativeRoot
        p.environment = e
        p.arguments = ["-i", nxnativeRoot.appendingPathComponent(".venv/bin/python").path, "scripts/build_ipa_from_nsp.py",
                       gamesRoot.appendingPathComponent(next).path, "-k", keys, "--platform", "mac-app", "--allow-other-metal",
                       "--progress", "json"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        var buffer = Data()
        var status = BuildStatus(stage: "Starting", step: "", k: 1, n: 8)   // owned by the reader's queue
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]; buffer = buffer[(nl + 1)...]
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    write(String(decoding: line, as: UTF8.self)); continue
                }
                guard let self else { return }
                self.handle(obj, &status, write: write)
                let snapshot = status
                DispatchQueue.main.async { if self.active == next { self.live[next] = snapshot } }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { log?.write(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            write("EXIT \(next): \(proc.terminationStatus)")
            try? log?.close()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stopping { self.message = nil }
                else if proc.terminationStatus != 0 { self.message = "The build of \(next) stopped with an error: see its log in the Builds page" }
                else if UserDefaults.standard.object(forKey: "cleanUpAfterBuild") as? Bool ?? true { Self.cleanUp(next) }
                self.stopping = false
                self.live[next] = nil
                self.active = nil; self.proc = nil
                self.startNext()
            }
        }
        do { try p.run(); proc = p } catch { active = nil; live[next] = nil; message = error.localizedDescription }
    }

    /// One `--progress json` event: update the live status, and keep the log readable for people
    /// (and for readBuildStatus, which follows builds NX OS didn't start).
    private func handle(_ ev: [String: Any], _ st: inout BuildStatus, write: (String) -> Void) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let k = ev["k"] as? Int, name = ev["name"] as? String, step = ev["step"] as? String
        switch ev["ev"] as? String {
        case "stage":
            st.k = k ?? st.k; st.n = ev["n"] as? Int ?? st.n
            st.stage = name ?? st.stage; st.step = step ?? ""; st.percent = nil; st.eta = nil
            write("[\(time)] [\(st.k)/\(st.n)] \(st.stage)" + (st.step.isEmpty ? "" : " · \(st.step)") + " …")
        case "step":
            st.step = step ?? st.step; st.percent = nil; st.eta = nil
            write("[\(time)] [\(st.k)/\(st.n)] \(st.stage) · \(st.step) …")
        case "progress":
            st.step = step ?? st.step
            if let f = ev["frac"] as? Double { st.percent = Int(f * 100) }
            if let eta = ev["eta"] as? Double { st.eta = String(format: "%d:%02d", Int(eta) / 60, Int(eta) % 60) } else { st.eta = nil }
            if let done = ev["done"] as? Double, let total = ev["total"] as? Double, total > 0 {
                let unit = ev["unit"] as? String ?? ""
                st.detail = unit == "B" ? "\(ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
                    : "\(Int(done)) of \(Int(total))" + (unit.isEmpty ? "" : " \(unit)")
            }
            if Date().timeIntervalSince(lastLogged) > 10 {
                lastLogged = Date()
                write("[\(time)] [\(st.k)/\(st.n)] \(st.stage) · \(st.step): \(st.percent.map { "\($0)%" } ?? "") \(st.eta.map { "ETA \($0)" } ?? "")")
            }
        case "stage_end":
            st.percent = 100; st.detail = nil
            let ok = ev["ok"] as? Bool ?? true
            write("[\(time)] \(ok ? "✓" : "✗") [\(st.k)/\(st.n)] \(name ?? st.stage)" + ((ev["summary"] as? String).map { ": \($0)" } ?? ""))
        case "say":
            if let msg = ev["msg"] as? String { write("[\(time)] \(msg)") }
        default: break
        }
    }

    /// After a finished build the .app holds everything the game needs (code, RomFS, shaders, pipeline
    /// archive; saves are in ~/Library/Application Support/nxnative), so the build folder and the
    /// packer's .app.key go. The dumps stay, so the game can be built again.
    static func cleanUp(_ folder: String) {
        let dir = gamesRoot.appendingPathComponent(folder)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            // only when a finished app is there and no half-written one
            guard items.contains(where: { $0.hasSuffix(".app") }), !items.contains(where: { $0.hasSuffix(".app.partial") }) else { return }
            for name in items where name.hasSuffix("_build") || name.hasSuffix(".app.key") || name.hasPrefix("._") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// The newest log that mentions this game folder.
    static func log(for folder: String) -> URL? {
        let own = gamesRoot.appendingPathComponent("nxnative-\(folder).log")
        if FileManager.default.fileExists(atPath: own.path) { return own }
        let logs = ((try? FileManager.default.contentsOfDirectory(at: gamesRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
        return logs.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("/Games/\(folder)/") == true }
    }

    func updateNxnative(done: @escaping (String) -> Void) {
        updating = true
        DispatchQueue.global().async {
            let out = shell("/usr/bin/git", ["-C", nxnativeRoot.path, "pull", "--ff-only"])
            DispatchQueue.main.async { self.updating = false; done(out) }
        }
    }
}

// MARK: - System information

@discardableResult
func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return error.localizedDescription }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

enum SystemInfo {
    static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    static let chip = sysctl("machdep.cpu.brand_string")
    static let memory = "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    static let macOS = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "macOS ")
    static var nxnativeVersion: String {
        shell("/usr/bin/git", ["-C", nxnativeRoot.path, "log", "-1", "--format=%h · %cr"])
    }
    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }
    /// The name of the drive holding the games folder, like "T7" or "Macintosh HD".
    static var driveName: String {
        (try? gamesRoot.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "this Mac"
    }
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let k: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = (try? a.resourceValues(forKeys: k))?.volumeIdentifier as? NSObject,
              let y = (try? b.resourceValues(forKeys: k))?.volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }
    /// How full the games drive is, 0…1.
    static var t7UsedFraction: Double {
        guard let v = try? gamesRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacity, let total = v.volumeTotalCapacity, total > 0 else { return 0 }
        return 1 - Double(free) / Double(total)
    }
    static var t7Free: String {
        guard let v = try? gamesRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let free = v.volumeAvailableCapacity else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file) + " free"
    }
}
