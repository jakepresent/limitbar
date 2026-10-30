import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// One native status button: left click toggles the non-activating usage panel;
/// right click opens appearance/app controls. Hover never opens or closes anything.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var item: NSStatusItem!
    private var tray: PassThroughHostingView<TrayView>!
    private(set) var panel: NSPanel!
    private var panelHost: NSHostingView<AnyView>!
    private let store: Store
    private let preferences: DisplayPreferences
    private var subs = Set<AnyCancellable>()
    private var globalOutsideClick: Any?
    private var localOutsideClick: Any?
    private let usage = UsageStore()
    private let ui = PanelState()
    private var usageTimer: Timer?

    init(store: Store = Store(), preferences: DisplayPreferences = DisplayPreferences()) {
        self.store = store
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.rememberProviders(store.installed)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        tray = PassThroughHostingView(rootView: TrayView(store: store, preferences: preferences))
        tray.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(tray)
        NSLayoutConstraint.activate([tray.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                     tray.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("AI subscription limits")
        buildPanel()
        resizeItem()
        store.$snaps.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.preferences.rememberProviders(self.store.installed)
                self.resizeItem()
                self.resizePanel()
            }
        }.store(in: &subs)
        store.$busy.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }.store(in: &subs)
        preferences.objectWillChange.sink { [weak self] _ in
            // Published values and SwiftUI's intrinsic size update after this notification.
            DispatchQueue.main.async { self?.resizeItem(); self?.resizePanel() }
        }.store(in: &subs)
        // The Usage page changes the panel's height: on every switch and whenever new totals arrive. Each
        // change measures the natural height again (scrolling off) before deciding whether it must scroll.
        Publishers.MergeMany(ui.$page.map { _ in () }.eraseToAnyPublisher(), ui.$range.map { _ in () }.eraseToAnyPublisher(),
                             usage.$summary.map { _ in () }.eraseToAnyPublisher(), usage.$reading.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.ui.scrolls = false; DispatchQueue.main.async { self?.resizePanel() } }
            }.store(in: &subs)
        ui.$scrolls.dropFirst().filter { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }.store(in: &subs)
        ui.$page.sink { [weak self] page in
            guard let self = self, self.panel?.isVisible == true else { return }
            if page == .usage { self.usage.refresh() } else { self.usage.pause() }
        }.store(in: &subs)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hide()
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
    }

    private func resizeItem() {
        tray.invalidateIntrinsicContentSize()
        tray.layoutSubtreeIfNeeded()
        item.length = ceil(tray.fittingSize.width)
        item.button?.toolTip = nil
        let values = preferences.orderedProviders(store.installed).map { vendor in
            let reading = TrayReading(snapshot: store.snaps[vendor], choice: preferences.choice(for: vendor))
            let label = reading.window?.label ?? preferences.choice(for: vendor)?.label ?? "Usage"
            return "\(vendor.name), \(label), \(reading.text)" + (reading.otherHot ? ", another limit is nearly exhausted" : "")
        }
        item.button?.setAccessibilityValue(values.joined(separator: "; "))
    }

    // MARK: panel

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 400),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        // Behind-window material has its own surface; layer clipping alone leaves square corners.
        // A stretchable material mask also gives the window shadow the rounded outline.
        let radius: CGFloat = 16
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        fx.maskImage = mask

        panelHost = NSHostingView(rootView: AnyView(PanelView(store: store, preferences: preferences, usage: usage, ui: ui)))
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(panelHost)
        NSLayoutConstraint.activate([panelHost.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                                     panelHost.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     panelHost.topAnchor.constraint(equalTo: fx.topAnchor),
                                     panelHost.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
    }

    private func resizePanel() {
        guard panel != nil else { return }
        panelHost.layoutSubtreeIfNeeded()
        let size = panelHost.fittingSize
        guard size.height > 0, let button = item.button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = (win.screen ?? NSScreen.main)?.visibleFrame else { return }   // no display attached
        // Taller than the screen (many models on Usage): the middle scrolls instead. The natural height is
        // measured without scrolling; the flag change re-renders and calls this again.
        let room = screen.height - 16
        if ui.maxHeight != room { ui.maxHeight = room }
        if !ui.scrolls, size.height > room { ui.scrolls = true; return }
        let height = min(size.height, room)
        var x = r.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = max(r.minY - height - 5, screen.minY + 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: height), display: panel.isVisible)
    }

    private func show() {
        guard !panel.isVisible else { return }
        store.refresh(olderThan: 90)      // panel open: only sources older than 90 s
        if ui.page == .usage { usage.refresh() }   // logs are read only for someone looking at them
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible, self.ui.page == .usage else { return }
            self.usage.refresh()
        }
        resizePanel()
        panel.orderFrontRegardless()
        item.button?.highlight(true)
        globalOutsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideMouseDown(event)
        }
        localOutsideClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide(); return nil }
                return event
            }
            self.handleOutsideMouseDown(event)
            return event
        }
    }

    func handleOutsideMouseDown(_ event: NSEvent) {
        if event.window === panel { return }
        // The menu-bar system can own a status-item mouse-down. Its global-monitor event
        // has no local NSWindow, and locationInWindow is already in screen coordinates.
        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if let host = item.button?.window {
            // The native status-item slot includes padding around the button and reaches
            // the screen edge. Include its boundaries, not just the inset button bounds.
            let frame = host.frame
            if location.x >= frame.minX && location.x <= frame.maxX &&
               location.y >= frame.minY && location.y <= frame.maxY { return }
        }
        hide()
    }

    private func hide() {
        panel?.orderOut(nil)
        item?.button?.highlight(false)
        if let monitor = globalOutsideClick { NSEvent.removeMonitor(monitor); globalOutsideClick = nil }
        if let monitor = localOutsideClick { NSEvent.removeMonitor(monitor); localOutsideClick = nil }
        usageTimer?.invalidate(); usageTimer = nil
        usage.pause()
    }

    @objc private func clicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: right-click menu

    private func showContextMenu() {
        hide()
        guard let button = item.button else { return }
        button.highlight(true)
        makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
        button.highlight(false)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let styleItem = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for style in MenuBarStyle.allCases {
            let option = NSMenuItem(title: style.title, action: #selector(changeStyle(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = style.rawValue
            option.state = preferences.style == style ? .on : .off
            styles.addItem(option)
        }
        styleItem.submenu = styles
        menu.addItem(styleItem)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit LimitBar", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenuBarStyle(rawValue: raw) else { return }
        preferences.setStyle(style)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The whole grid belongs to one native status button; provider readouts never swallow clicks.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
