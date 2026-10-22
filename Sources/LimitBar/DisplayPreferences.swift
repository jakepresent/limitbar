import Combine
import Foundation

/// Stable identity for a limit. Usage and reset dates change on every refresh.
struct WindowChoice: Codable, Equatable {
    let label: String
    let short: String

    init(_ window: Window) {
        label = window.label
        short = window.short
    }

    func matches(_ window: Window) -> Bool {
        label == window.label && short == window.short
    }
}

enum MenuBarStyle: String, CaseIterable {
    case grid
    case iconOnly

    var title: String { self == .grid ? "Usage Grid" : "Icon Only" }
}

/// Presentation preferences are separate from fetched/cached readings.
final class DisplayPreferences: ObservableObject {
    @Published private(set) var style: MenuBarStyle
    @Published private var choices: [String: WindowChoice]
    @Published private var providerOrder: [Vendor]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .grid
        choices = defaults.data(forKey: "menuBarWindows")
            .flatMap { try? JSONDecoder().decode([String: WindowChoice].self, from: $0) } ?? [:]
        providerOrder = (defaults.stringArray(forKey: "menuBarProviderOrder") ?? []).compactMap(Vendor.init(rawValue:))
    }

    func setStyle(_ style: MenuBarStyle) {
        guard self.style != style else { return }
        self.style = style
        defaults.set(style.rawValue, forKey: "menuBarStyle")
    }

    func choice(for vendor: Vendor) -> WindowChoice? { choices[vendor.rawValue] }

    func select(_ window: Window, for vendor: Vendor) {
        choices[vendor.rawValue] = WindowChoice(window)
        saveChoices()
    }

    func useDefaultWindow(for vendor: Vendor) {
        choices.removeValue(forKey: vendor.rawValue)
        saveChoices()
    }

    private func saveChoices() {
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: "menuBarWindows") }
    }

    /// Append newly discovered providers; installing another CLI must not rearrange existing rows.
    func rememberProviders(_ installed: [Vendor]) {
        let added = installed.filter { !providerOrder.contains($0) }
        guard !added.isEmpty else { return }
        providerOrder += added
        defaults.set(providerOrder.map(\.rawValue), forKey: "menuBarProviderOrder")
    }

    func orderedProviders(_ installed: [Vendor]) -> [Vendor] {
        providerOrder.filter { installed.contains($0) } + installed.filter { !providerOrder.contains($0) }
    }
}

enum TrayLayout {
    static func columns(_ providers: [Vendor]) -> [[Vendor]] {
        stride(from: 0, to: providers.count, by: 2).map {
            Array(providers[$0..<min($0 + 2, providers.count)])
        }
    }
}

/// One presentation rule for the tray, its accessibility value, and attention indicators.
struct TrayReading {
    let window: Window?
    let used: Double?
    let weekly: Bool
    let otherHot: Bool

    init(snapshot: Snapshot?, choice: WindowChoice?) {
        let selected: Window?
        if let choice = choice {
            selected = snapshot?.windows.first(where: choice.matches)
        } else {
            selected = snapshot?.bar
        }
        window = snapshot?.state == .ok ? selected : nil
        used = window.flatMap { $0.resetPassed ? nil : $0.used }
        weekly = (choice?.short ?? window?.short) == "w"
        let selectedChoice = window.map(WindowChoice.init)
        otherHot = snapshot?.state == .ok && (snapshot?.windows.contains {
            !$0.resetPassed && ($0.used ?? 0) >= 90 && WindowChoice($0) != selectedChoice
        } ?? false)
    }

    var critical: Bool { (used ?? 0) >= 90 }
    var text: String { used.map { percentText($0) + "%" } ?? "—" }
    var marker: String { (weekly ? "w" : "") + (otherHot ? "!" : "") }
}
