import AppKit
import SwiftUI
import Foundation

let args = CommandLine.arguments

// `LimitBar --probe` asks every CLI once and prints what limitbar would show, as JSON:
// state (ok / missing / untrusted / signedOut / failed), plan, windows. Nothing else of the account.
if args.contains("--probe") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    var all: [String: Snapshot] = [:]
    for v in Vendor.allCases {
        switch v {
        case .claude:
            var s: Snapshot
            let (bin, why) = Fetch.binary(.claude)
            if bin == nil { s = why! }
            else if let acct = Fetch.claudeAccount(), !acct.signedIn { s = .status(.claude, .signedOut) }
            else { s = Fetch.claudeFile() ?? Fetch.claudeUsage(); s.plan = Fetch.claudeAccount()?.plan ?? s.plan }
            all[v.rawValue] = s
        case .gemini: all[v.rawValue] = Fetch.gemini()
        case .codex: all[v.rawValue] = Fetch.codexFromServer()
        case .grok: all[v.rawValue] = Fetch.grok()
        }
    }
    print(String(decoding: (try? enc.encode(all)) ?? Data(), as: UTF8.self))
    exit(0)
}

// `LimitBar --statusline` — optional Claude Code status line (see README). Claude Code pipes a JSON blob
// with the current rate limits to it on every refresh; we keep only the limits, in
// ~/Library/Caches/limitbar/claude-status.json, and print one short line, e.g. "5h 23% · 7d 41%".
// The menu bar then reads Claude's numbers for free instead of running `claude -p /usage`.
if args.contains("--statusline") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let blob = Fetch.json(input) ?? [:]
    let rl = (blob["rate_limits"] ?? blob["rateLimits"]) as? [String: Any] ?? [:]
    var limits: [String: Any] = [:]
    for (kind, value) in rl {
        guard let w = value as? [String: Any] else { continue }
        var pct = ["used_percentage", "used_percent", "percentUsed", "percent", "utilization"].lazy
            .compactMap { w[$0] as? Double }.first
        if let p = pct, p <= 1, w["utilization"] != nil { pct = p * 100 }
        guard let p = percent(pct) else { continue }
        limits[kind] = ["percent": p, "resets_at": w["resets_at"] ?? w["resetsAt"] ?? w["reset_at"] ?? NSNull()]
    }
    if !limits.isEmpty,   // only a refresh that carries limits replaces the last good file
       let d = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "limits": limits]) {
        Paths.write(d, to: Fetch.claudeFilePath)
    }
    let parts = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { k, label -> String? in
        guard let p = (limits[k] as? [String: Any])?["percent"] as? Double else { return nil }
        return "\(label) \(percentText(p))%"
    }
    let model = ((blob["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"
    print(([model] + parts).joined(separator: " · "))
    exit(0)
}

#if DEBUG
// `LimitBar --render-panel <out.png>` (debug builds only): draw the limits panel from cached readings.
if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
    let view = PanelView(store: Store(live: false), preferences: DisplayPreferences())
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.17, green: 0.17, blue: 0.18)))
        .environment(\.colorScheme, .dark)
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
