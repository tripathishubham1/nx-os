// First-run setup: where the games live and where the nxnative checkout is. Shown until a games
// folder is chosen, again when that folder goes missing, and from System > Folders.
import SwiftUI
import AppKit

struct SetupView: View {
    /// true when the folders were set before and this is a change, not the first launch.
    var editing = false
    let done: () -> Void
    @State private var games: URL? = UserDefaults.standard.string(forKey: Paths.gamesKey).map { URL(fileURLWithPath: $0) }
    @State private var nxnative: URL? = UserDefaults.standard.string(forKey: Paths.nxnativeKey).map { URL(fileURLWithPath: $0) }

    private var keysFound: Bool { BuildQueue.findKeys() != nil }
    private var gamesOK: Bool { games.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private var nxnativeOK: Bool { nxnative.map(Paths.isNxnative) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editing ? "Folders" : "Welcome to NX OS").font(.ui(24, .heavy)).foregroundStyle(.white)
                    Text("Choose where your games live and where nxnative is checked out.")
                        .font(.ui(13)).foregroundStyle(Theme.ink2)
                }
            }
            VStack(spacing: 10) {
                row(icon: "folder.fill", title: "Games folder",
                    detail: "Each game gets its own folder here, next to your dump.",
                    url: games, ok: gamesOK, problem: "Choose a folder") { choose(create: true) { games = $0 } }
                row(icon: "hammer.fill", title: "nxnative",
                    detail: "Your clone of github.com/seedds/nxnative, set up as its README says.",
                    url: nxnative, ok: nxnativeOK,
                    problem: nxnative == nil ? "Needed to build games" : "No scripts/build_ipa_from_nsp.py here") {
                    choose(create: false) { nxnative = $0 }
                }
                row(icon: "key.fill", title: "Keys",
                    detail: "Your own prod.keys, dumped from your Switch, in ~/.switch/prod.keys.",
                    url: BuildQueue.findKeys().map { URL(fileURLWithPath: $0) }, ok: keysFound,
                    problem: "Not found. You can add them later.", button: nil)
            }
            HStack {
                Text("NX OS includes no games or keys. Only build games you own.")
                    .font(.ui(12)).foregroundStyle(Theme.ink2)
                Spacer()
                if editing { PillButton(title: "Cancel") { done() } }
                CTAButton(title: editing ? "Save" : "Continue", icon: "arrow.right") { save() }
                    .opacity(gamesOK ? 1 : 0.4).disabled(!gamesOK)
            }
        }
        .padding(30)
        .frame(width: 640)
        .raised(26, fill: Theme.rail, lit: true)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }

    private func row(icon: String, title: String, detail: String, url: URL?, ok: Bool, problem: String,
                     button: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            IconTile(icon: icon, tint: ok ? mint : .yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(14, .bold)).foregroundStyle(.white)
                Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? detail)
                    .font(.ui(12)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                if !ok {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(11, .semibold)).foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 12)
            if let button { PillButton(title: url == nil ? "Choose…" : "Change…", icon: "folder", action: button) }
        }
        .padding(14)
        .raised(16)
    }

    private func choose(create: Bool, _ set: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = create
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { set(url) }
    }

    private func save() {
        guard let games else { return }
        UserDefaults.standard.set(games.path, forKey: Paths.gamesKey)
        if let nxnative { UserDefaults.standard.set(nxnative.path, forKey: Paths.nxnativeKey) }
        done()
    }
}

