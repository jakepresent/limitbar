import AppKit
import SwiftUI
import XCTest
@testable import LimitBar

final class DisplayTests: XCTestCase {
    private func window(_ label: String = "Week", _ short: String = "w", _ used: Double = 70,
                        reset: Date? = .distantFuture) -> LimitBar.Window {
        Window(label: label, short: short, used: used, resetsAt: reset)
    }

    private func withPreferences(_ body: (DisplayPreferences, UserDefaults) throws -> Void) rethrows {
        let name = "limitbar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(DisplayPreferences(defaults: defaults), defaults)
    }

    func testGridFillsColumnsTopToBottomForZeroThroughFourProviders() {
        let providers: [Vendor] = [.claude, .codex, .gemini, .grok]
        let expected: [[[Vendor]]] = [[], [[.claude]], [[.claude, .codex]],
                                     [[.claude, .codex], [.gemini]],
                                     [[.claude, .codex], [.gemini, .grok]]]
        for count in 0...4 {
            XCTAssertEqual(TrayLayout.columns(Array(providers.prefix(count))), expected[count])
        }
    }

    func testDefaultWindowStillUsesFetcherRecommendation() {
        let five = window("5-hour", "5h", 14)
        let week = window()
        let snap = Snapshot(vendor: .claude, bar: five, windows: [five, week])
        XCTAssertEqual(TrayReading(snapshot: snap, choice: nil).window, five)
    }

    func testWeeklyChoiceOverridesDefaultAndIncludesPercentAndWeekMarker() {
        let five = window("5-hour", "5h", 14)
        let week = window()
        let snap = Snapshot(vendor: .claude, bar: five, windows: [five, week])
        let reading = TrayReading(snapshot: snap, choice: WindowChoice(week))
        XCTAssertEqual(reading.window, week)
        XCTAssertEqual(reading.text, "70%")
        XCTAssertEqual(reading.marker, "w")
    }

    func testChoiceUsesIdentityNotUsageResetOrWindowOrder() {
        let old = window()
        let latest = window("Week", "w", 81)
        let modelWeek = window("Week Sonnet", "w", 12)
        let five = window("5-hour", "5h", 40)
        let snap = Snapshot(vendor: .claude, bar: five, windows: [modelWeek, latest, five])
        XCTAssertEqual(TrayReading(snapshot: snap, choice: WindowChoice(old)).window, latest)
    }

    func testUnavailableChosenWindowDoesNotSilentlySwitchToHourly() {
        let five = window("5-hour", "5h", 14)
        let snap = Snapshot(vendor: .claude, bar: five, windows: [five])
        let reading = TrayReading(snapshot: snap, choice: WindowChoice(window()))
        XCTAssertNil(reading.window)
        XCTAssertEqual(reading.text, "—")
        XCTAssertEqual(reading.marker, "w")
    }

    func testResetPassedDoesNotShowObsoleteUsageAsZero() {
        let week = window(reset: .distantPast)
        let reading = TrayReading(snapshot: Snapshot(vendor: .claude, bar: week, windows: [week]), choice: nil)
        XCTAssertNil(reading.used)
        XCTAssertEqual(reading.text, "—")
        XCTAssertFalse(reading.critical)
    }

    func testOtherLimitWarningIsRelativeToSelectedWindow() {
        let five = window("5-hour", "5h", 95)
        let week = window()
        let snap = Snapshot(vendor: .claude, bar: five, windows: [five, week])
        let reading = TrayReading(snapshot: snap, choice: WindowChoice(week))
        XCTAssertFalse(reading.critical)
        XCTAssertTrue(reading.otherHot)
        XCTAssertEqual(reading.marker, "w!")
        XCTAssertFalse(TrayReading(snapshot: snap, choice: nil).otherHot)
    }

    func testExpiredOtherWindowDoesNotRaiseWarning() {
        let five = window("5-hour", "5h", 95, reset: .distantPast)
        let week = window()
        let snap = Snapshot(vendor: .claude, bar: five, windows: [five, week])
        XCTAssertFalse(TrayReading(snapshot: snap, choice: WindowChoice(week)).otherHot)
    }

    func testSignedOutSnapshotDoesNotShowCachedNumbersOrWarnings() {
        let week = window("Week", "w", 95)
        let snap = Snapshot(vendor: .claude, state: .signedOut, bar: week, windows: [week])
        let reading = TrayReading(snapshot: snap, choice: nil)
        XCTAssertEqual(reading.text, "—")
        XCTAssertFalse(reading.critical)
        XCTAssertFalse(reading.otherHot)
    }

    func testStyleAndWindowChoicesPersistIndependentlyPerProvider() {
        withPreferences { prefs, defaults in
            XCTAssertEqual(prefs.style, .grid)
            prefs.setStyle(.iconOnly)
            prefs.select(window(), for: .claude)
            prefs.select(window("5-hour", "5h", 22), for: .codex)
            let restored = DisplayPreferences(defaults: defaults)
            XCTAssertEqual(restored.style, .iconOnly)
            XCTAssertEqual(restored.choice(for: .claude), WindowChoice(window()))
            XCTAssertEqual(restored.choice(for: .codex)?.short, "5h")
            restored.useDefaultWindow(for: .claude)
            let again = DisplayPreferences(defaults: defaults)
            XCTAssertNil(again.choice(for: .claude))
            XCTAssertEqual(again.choice(for: .codex)?.short, "5h")
        }
    }

    func testNewProviderDoesNotMoveExistingRowsAndOrderSurvivesRelaunch() {
        withPreferences { prefs, defaults in
            prefs.rememberProviders([.claude, .codex])
            prefs.rememberProviders([.claude, .gemini, .codex])
            XCTAssertEqual(prefs.orderedProviders([.claude, .gemini, .codex]), [.claude, .codex, .gemini])
            let restored = DisplayPreferences(defaults: defaults)
            XCTAssertEqual(restored.orderedProviders([.claude, .gemini, .codex]), [.claude, .codex, .gemini])
            XCTAssertEqual(restored.orderedProviders([.gemini, .codex]), [.codex, .gemini])
        }
    }

    func testUnknownAndMissingProvidersDoNotReserveRows() {
        XCTAssertTrue(Store(initialSnapshots: [:]).installed.isEmpty)
        let store = Store(initialSnapshots: [.claude: .status(.claude, .signedOut),
                                             .codex: .status(.codex, .failed),
                                             .gemini: .status(.gemini, .missing)])
        XCTAssertEqual(store.installed, [.claude, .codex])
    }

    @MainActor
    func testNativeHostingViewFitsTwoRowsAndFourProviders() {
        _ = NSApplication.shared
        withPreferences { prefs, _ in
            let providers: [Vendor] = [.claude, .codex, .gemini, .grok]
            let snapshots = Dictionary(uniqueKeysWithValues: providers.map {
                let week = window("Week", "w", 99.6)
                return ($0, Snapshot(vendor: $0, bar: week, windows: [week], measuredAt: Date()))
            })
            @MainActor func measure(_ providers: [Vendor]) -> NSSize {
                let filtered = snapshots.filter { providers.contains($0.key) }
                let view = NSHostingView(rootView: TrayView(store: Store(initialSnapshots: filtered), preferences: prefs))
                view.layoutSubtreeIfNeeded()
                return view.fittingSize
            }
            let two = measure([.claude, .codex])
            let four = measure(providers)
            XCTAssertEqual(two.height, 22, accuracy: 0.1)
            XCTAssertEqual(four.height, 22, accuracy: 0.1)
            XCTAssertGreaterThan(four.width, two.width)
            XCTAssertLessThanOrEqual(four.width, 2 * two.width + 8)
            prefs.setStyle(.iconOnly)
            let icon = measure(providers)
            XCTAssertLessThan(icon.width, two.width)
            XCTAssertEqual(icon.height, 22, accuracy: 0.1)
            XCTAssertNotNil(NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil))
            print("TRAY_FITTING_SIZE two=\(two), four=\(four), icon=\(icon)")
        }
    }

    @MainActor
    func testNativeStatusButtonTogglesPanelAndStyleMenuActionsResizeIt() throws {
        _ = NSApplication.shared
        try withPreferences { prefs, _ in
            let week = window()
            let snapshots: [Vendor: Snapshot] = [
                .claude: Snapshot(vendor: .claude, bar: week, windows: [week], measuredAt: Date()),
                .codex: Snapshot(vendor: .codex, bar: week, windows: [week], measuredAt: Date())
            ]
            let delegate = AppDelegate(store: Store(initialSnapshots: snapshots), preferences: prefs)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
            let button = try XCTUnwrap(delegate.item.button)
            XCTAssertFalse(delegate.panel.isVisible)
            for _ in 0..<3 {
                button.performClick(nil)
                XCTAssertTrue(delegate.panel.isVisible)
                button.performClick(nil)
                XCTAssertFalse(delegate.panel.isVisible)
            }
            let gridWidth = delegate.item.length
            let menu = delegate.makeContextMenu()
            let styles = try XCTUnwrap(menu.item(withTitle: "Menu Bar Style")?.submenu)
            XCTAssertEqual(styles.item(withTitle: "Usage Grid")?.state, .on)
            let icon = try XCTUnwrap(styles.item(withTitle: "Icon Only"))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(icon.action), to: icon.target, from: icon))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(prefs.style, .iconOnly)
            XCTAssertLessThan(delegate.item.length, gridWidth)
            XCTAssertEqual(delegate.makeContextMenu().item(withTitle: "Menu Bar Style")?.submenu?.item(withTitle: "Icon Only")?.state, .on)
            XCTAssertNotNil(menu.item(withTitle: "Launch at Login"))
            XCTAssertNotNil(menu.item(withTitle: "Quit LimitBar"))
            button.performClick(nil)
            XCTAssertTrue(delegate.panel.isVisible)
            button.performClick(nil)
            XCTAssertFalse(delegate.panel.isVisible)
        }
    }

    func testCriticalUsageAndRoundingPreserveExistingSemantics() {
        let almost = window("Week", "w", 99.6)
        let reading = TrayReading(snapshot: Snapshot(vendor: .claude, bar: almost, windows: [almost]), choice: nil)
        XCTAssertTrue(reading.critical)
        XCTAssertEqual(reading.text, "99%")
        XCTAssertEqual(percentText(100), "100")
    }
}
