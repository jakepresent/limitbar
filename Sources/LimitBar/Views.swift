import AppKit
import SwiftUI


enum Marks {
    private static var cache: [String: NSImage] = [:]

    static func image(_ v: Vendor) -> NSImage {
        if let i = cache[v.mark] { return i }
        let url = Bundle.main.resourceURL?.appendingPathComponent("marks/\(v.mark).svg")
        let img = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        cache[v.mark] = img
        return img
    }
}

extension Color {
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let hot = Color(nsColor: .systemRed)
    static let geminiGradient = LinearGradient(colors: [Color(red: 0x3D / 255, green: 0x8B / 255, blue: 1),
                                                       Color(red: 0xB0 / 255, green: 0x6B / 255, blue: 0xDB / 255)],
                                              startPoint: .leading, endPoint: .trailing)
}

private let staleAfter: TimeInterval = 45 * 60

private func isStale(_ s: Snapshot?) -> Bool {
    guard let m = s?.measuredAt else { return true }
    return Date().timeIntervalSince(m) > staleAfter
}

// MARK: - Tray: two rows per column, or one compact template icon

struct TrayView: View {
    @ObservedObject var store: Store
    @ObservedObject var preferences: DisplayPreferences

    private var providers: [Vendor] { preferences.orderedProviders(store.installed) }

    var body: some View {
        Group {
            if preferences.style == .iconOnly || providers.isEmpty {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 15))
                    .foregroundStyle(needsAttention ? Color.hot : Color.primary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(TrayLayout.columns(providers).enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(column, id: \.self) { vendor in
                                HStack(spacing: 3) {
                                    Image(nsImage: Marks.image(vendor)).renderingMode(.template).resizable()
                                        .interpolation(.high).frame(width: 9, height: 9)
                                    digit(vendor)
                                }
                                .frame(height: 11)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, preferences.style == .iconOnly || providers.isEmpty ? 7 : 0)
        .frame(height: 22)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI subscription limits")
        .accessibilityValue(providers.map { vendor in
            let reading = TrayReading(snapshot: store.snaps[vendor], choice: preferences.choice(for: vendor))
            let label = reading.window?.label ?? preferences.choice(for: vendor)?.label ?? "Usage"
            return "\(vendor.name), \(label), \(reading.text)" + (reading.otherHot ? ", another limit is nearly exhausted" : "")
        }.joined(separator: "; "))
    }

    private var needsAttention: Bool {
        providers.contains {
            let reading = TrayReading(snapshot: store.snaps[$0], choice: preferences.choice(for: $0))
            return reading.critical || reading.otherHot
        }
    }

    private func digit(_ vendor: Vendor) -> some View {
        let snap = store.snaps[vendor]
        let reading = TrayReading(snapshot: snap, choice: preferences.choice(for: vendor))
        var text = Text(reading.text)
            .font(.system(size: 10, weight: reading.critical ? .semibold : .regular).monospacedDigit())
        if !reading.marker.isEmpty {
            text = text + Text(reading.marker).font(.system(size: 6, weight: .semibold)).baselineOffset(3)
        }
        return text.foregroundStyle(reading.critical ? Color.hot : Color.primary)
            .opacity(isStale(snap) && reading.used != nil ? 0.5 : 1)
            .fixedSize()
    }
}

// MARK: - Panel: 328 pt glass, one section per vendor, bars in brand colours

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var preferences: DisplayPreferences

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                ForEach(Array(store.installed.enumerated()), id: \.element) { i, v in
                    if i > 0 { Hairline() }
                    VendorSection(vendor: v, snap: store.snaps[v], busy: store.busy.contains(v), preferences: preferences)
                }
                if store.installed.isEmpty {
                    Text("No providers found").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                }
                Hairline()
                footer
            }
            .frame(width: 328)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(title: store.busy.isEmpty ? "Refresh" : "Refreshing…") { store.refresh(force: true) }
                .disabled(!store.busy.isEmpty)
            Spacer()
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct VendorSection: View {
    let vendor: Vendor
    let snap: Snapshot?
    let busy: Bool
    @ObservedObject var preferences: DisplayPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                markView.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vendor.name).font(.system(size: 13, weight: .semibold)).tracking(-0.2)
                    Text(planLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ageText).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
            }
            let windows = snap?.windows ?? []
            ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                MeterRow(window: w, vendor: vendor,
                         style: i == 0 ? .primary : (w.label == "5-hour" || w.label == "Week" ? .normal : .quiet))
                    .padding(.top, 7)
                    .opacity(isStale(snap) ? 0.48 : 1)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { preferences.select(w, for: vendor) } label: {
                            if preferences.choice(for: vendor)?.matches(w) == true {
                                Label("Shown in Menu Bar", systemImage: "checkmark")
                            } else {
                                Text("Show in Menu Bar")
                            }
                        }
                        Button("Use Default Window") { preferences.useDefaultWindow(for: vendor) }
                            .disabled(preferences.choice(for: vendor) == nil)
                    }
            }
            if snap?.state == .signedOut {
                Text("Signed out — \(vendor.loginHint)").font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 7)
            } else if windows.isEmpty {
                Text(busy ? "Reading…" : "—").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
            }
            ForEach(snap?.notes ?? [], id: \.self) { n in
                Text(n).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
            }
            if let e = snap?.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
    }

    @ViewBuilder private var markView: some View {
        let img = Image(nsImage: Marks.image(vendor)).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: 16, height: 16)
        switch vendor {
        case .claude: img.foregroundStyle(Color.claude)
        case .gemini: img.foregroundStyle(Color.geminiGradient)
        default: img.foregroundStyle(Color.primary)
        }
    }

    private var planLine: String {
        let plan = snap?.plan ?? ""
        return plan.isEmpty ? vendor.product : "\(vendor.product) · \(plan)"
    }

    private var ageText: String {
        if busy && snap?.measuredAt == nil { return "reading…" }
        guard let m = snap?.measuredAt else { return "" }
        let s = Int(Date().timeIntervalSince(m))
        let t = s < 60 ? "just now" : s < 3600 ? "\(s / 60) min ago" : s < 86400 ? "\(s / 3600) h ago" : "\(s / 86400) d ago"
        return "updated " + t
    }
}

private struct MeterRow: View {
    enum Style { case primary, normal, quiet }
    let window: Window
    let vendor: Vendor
    let style: Style

    var body: some View {
        let due = window.resetPassed
        let hot = !due && (window.used ?? 0) >= 90
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: style == .quiet ? 11 : 12, weight: style == .primary ? .semibold : .regular))
                    .foregroundStyle(style == .quiet ? .secondary : .primary)
                Text(resetText(due)).font(.system(size: 11)).foregroundStyle(due ? .secondary : .tertiary)
            }
            .frame(width: 118, alignment: .leading)
            if !due {
                Track(fraction: (window.used ?? 0) / 100, height: style == .quiet ? 4 : 5, vendor: vendor, hot: hot)
            } else {
                Spacer()
            }
            Text(due || window.used == nil ? "—" : percentText(window.used) + "%")
                .font(.system(size: style == .quiet ? 12 : 13,
                              weight: hot ? .bold : style == .primary ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(hot ? Color.hot : (style == .quiet || due ? Color.secondary : Color.primary))
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func resetText(_ due: Bool) -> String {
        if due { return "reset — awaiting update" }
        // Gemini rows are named after the model group, so the window length goes on this line.
        let kind = vendor == .gemini ? (window.short == "5h" ? "5-hour · " : "week · ") : ""
        guard let r = window.resetsAt else { return kind.isEmpty ? "" : String(kind.dropLast(3)) }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(r) ? "HH:mm" : "EEE HH:mm"
        return kind + (vendor == .grok ? "ends " : "resets ") + f.string(from: r)
    }
}

private struct Track: View {
    let fraction: Double
    let height: CGFloat
    let vendor: Vendor
    let hot: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                fill.frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private var fill: some View {
        if hot { Capsule().fill(Color.hot) }
        else {
            switch vendor {
            case .claude: Capsule().fill(Color.claude)
            case .gemini: Capsule().fill(Color.geminiGradient)
            default: Capsule().fill(Color.primary)
            }
        }
    }
}

