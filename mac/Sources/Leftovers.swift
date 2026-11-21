// Rumi — what deleted apps left behind (v2.1).
// Dragging an app to the Trash leaves its data in the Library: its container, its saved data, its window state.
// Those folders are named after the app's id ("com.maker.app"), which is how Rumi tells whose they were.
//
// Calling something a leftover when its app is still here would be the worst mistake this feature could make, so every
// rule leans towards saying nothing:
// - only folders named like an app id count; a folder with a plain name ("Notes", "Maker") is never judged
// - macOS's own are never judged
// - nothing counts if macOS can still find an app with that id anywhere (other disks and build folders included)
// - nothing counts if anything from the same maker is still installed, running, or set to start in the background
//   (makers share updaters and helpers between their apps)
// - nothing counts unless it has gone untouched for a month
// What passes is offered as "Check first", never "Safe", and goes to the Trash like everything else.
import AppKit

enum Leftovers {
    static let QUIET: Double = 30 * 86400
    /// The places an app's data sits under its id, inside Home's Library. (Caches are left to the Caches group.)
    static let PLACES = ["Library/Containers", "Library/Application Support", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs"]
    private static let TOPS: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "us", "ai", "tv", "sh", "so", "xyz", "de", "uk", "fr", "jp", "ch", "se", "nl", "it",
                                            "is", "im", "eu", "ca", "au", "pl", "at", "be", "dk", "no", "fi", "es", "cn", "kr", "in", "ru", "br", "cc", "to", "gg", "fm", "ly"]

    /// The app id a data folder is named after ("com.maker.app", or "com.maker.app.savedState"), or nil if it isn't one.
    static func appID(ofFolder name: String) -> String? {
        let id = name.hasSuffix(".savedState") ? String(name.dropLast(11)) : name
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.count <= 8, let top = parts.first, TOPS.contains(top.lowercased()), !id.contains(" "),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              !id.lowercased().hasPrefix("com.apple.") else { return nil }
        return id
    }

    /// "com.maker": who made it.
    static func maker(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() }

    /// Every maker with something on this Mac: apps in the usual places and the helpers inside them, what's running,
    /// and what's set to start in the background.
    static func makersHere() -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        func app(_ path: String) {
            guard let id = Bundle(path: path)?.bundleIdentifier else { return }
            ids.insert(id)
            for inside in ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/XPCServices", "Contents/PlugIns", "Contents/Frameworks", "Contents/SharedSupport", "Contents/Applications", "Contents/MacOS", "Contents/Resources"] {
                for n in (try? fm.contentsOfDirectory(atPath: path + "/" + inside)) ?? [] where n.hasSuffix(".app") || n.hasSuffix(".xpc") || n.hasSuffix(".appex") {
                    if let h = Bundle(path: path + "/" + inside + "/" + n)?.bundleIdentifier { ids.insert(h) }
                }
            }
        }
        for dir in ["/Applications", "/Applications/Utilities", HOME + "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Setapp"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                if n.hasSuffix(".app") { app(dir + "/" + n) }
                else if dir == "/Applications" || dir == HOME + "/Applications" {   // a maker's folder of apps
                    for m in (try? fm.contentsOfDirectory(atPath: dir + "/" + n)) ?? [] where m.hasSuffix(".app") { app(dir + "/" + n + "/" + m) }
                }
            }
        }
        for a in NSWorkspace.shared.runningApplications { if let id = a.bundleIdentifier { ids.insert(id) } }
        for dir in [HOME + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { ids.insert(n.hasSuffix(".plist") ? String(n.dropLast(6)) : n) }
        }
        return Set(ids.map(maker))
    }

    /// A name to show for an id whose app is gone: its last word, or the one before when the last says nothing.
    static func name(_ id: String) -> String {
        let dull: Set<String> = ["app", "mac", "macos", "osx", "desktop", "client", "helper", "main", "ios"]
        let parts = id.split(separator: ".").map(String.init)
        let word = parts.last(where: { !dull.contains($0.lowercased()) && $0.count > 1 }) ?? parts.last ?? id
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    struct Found { let id: String; var parts: [[String: Any]]; var size: Int64; var newest: Double }

    /// Which of these data folders belong to apps that are gone. `folders`: (the id it's named after, path, size, last
    /// changed). One answer per app, biggest first.
    static func find(_ folders: [(id: String, path: String, size: Int64, mtime: Double)], now: Double) -> [Found] {
        guard !folders.isEmpty else { return [] }
        let here = makersHere()
        var gone: [String: Found] = [:], verdict: [String: Bool] = [:]
        for f in folders {
            if verdict[f.id] == nil {
                verdict[f.id] = !here.contains(maker(f.id)) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: f.id) == nil
            }
            guard verdict[f.id] == true else { continue }
            var g = gone[f.id] ?? Found(id: f.id, parts: [], size: 0, newest: 0)
            g.parts.append(["path": f.path, "size": f.size]); g.size += f.size; g.newest = max(g.newest, f.mtime)
            gone[f.id] = g
        }
        return gone.values.filter { now - $0.newest >= QUIET }.sorted { $0.size > $1.size }
    }
}
