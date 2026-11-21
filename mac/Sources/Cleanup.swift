// Rumi — clean-up commands it runs for you (v2.1).
// Some tools keep their own stores and only their own command clears them properly: pnpm, Go, Xcode's simulators,
// Homebrew. Nothing they remove goes to the Trash, so it can't be undone, and Rumi says so before the second click.
// Only the commands listed here are ever run, word for word; the page names one, it never sends one.
import Foundation

enum Cleanup {
    static let COMMANDS: [String: [String]] = [
        "pnpm store prune": ["pnpm", "store", "prune"],
        "go clean -modcache": ["go", "clean", "-modcache"],
        "xcrun simctl delete unavailable": ["xcrun", "simctl", "delete", "unavailable"],
        "brew cleanup": ["brew", "cleanup"],
    ]
    /// Where command-line tools usually are. An app started from Finder doesn't get the Terminal's own list. Node's
    /// version managers keep each version in a folder of its own: the newest comes first.
    static let PLACES: [String] = {
        var p = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", HOME + "/Library/pnpm", HOME + "/.local/share/pnpm", HOME + "/.local/bin",
                 "/usr/local/go/bin", HOME + "/go/bin", HOME + "/.volta/bin", HOME + "/.asdf/shims", HOME + "/.local/share/mise/shims", HOME + "/.bun/bin"]
        let nvm = HOME + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        p += versions.map { nvm + "/" + $0 + "/bin" }
        return p
    }()

    static func find(_ tool: String) -> String? {
        PLACES.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a tool and wait for it (ten minutes at most). Returns whether it ended well and the last of what it printed.
    static func run(_ path: String, _ args: [String]) -> (ok: Bool, said: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // the tool's own folder first: pnpm needs the node that sits beside it
        env["PATH"] = ([(path as NSString).deletingLastPathComponent] + PLACES + [env["PATH"] ?? ""]).joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["CI"] = "1"   // no questions asked of a terminal that isn't there
        p.environment = env; p.currentDirectoryURL = URL(fileURLWithPath: HOME)
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        var out = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { out.append(d) } }
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: stop)
        p.waitUntilExit(); stop.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, String(text.suffix(300)))
    }

    /// The page asked for one of the commands by name. Returns ok, how much room came back, and why not if it didn't work.
    static func json(_ cmd: String) -> [String: Any] {
        guard let argv = COMMANDS[cmd] else { return ["ok": false, "error": "Rumi doesn't run that."] }
        guard let tool = find(argv[0]) else { return ["ok": false, "error": "Rumi can't find \(argv[0]). Copy the command and run it in Terminal."] }
        let before = diskInfo()["free"] as? Int64 ?? 0
        let r = run(tool, Array(argv.dropFirst()))
        let S = Store.shared
        S.lock.lock(); S.brewKept = nil; S.lock.unlock()   // what Homebrew keeps is measured again
        let freed = max(0, (diskInfo()["free"] as? Int64 ?? 0) - before)
        return r.ok ? ["ok": true, "freed": freed] : ["ok": false, "error": r.said.isEmpty ? "It stopped with an error." : r.said]
    }
}
