import AVFoundation
import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Test modes

enum Test {
    static let args = CommandLine.arguments

    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Tick --parse "<text>"… prints how each entry is read.
    static func parse(_ texts: ArraySlice<String>) {
        for text in texts {
            if let r = Parser.parse(text) {
                let until = r.until.map { " until \(Format.time($0))" } ?? ""
                print("\(text.padding(toLength: 18, withPad: " ", startingAt: 0)) → \(Format.length(r.seconds)) (\(Int(r.seconds))s)\(until)\(r.label.isEmpty ? "" : "  label “\(r.label)”")")
            } else {
                print("\(text.padding(toLength: 18, withPad: " ", startingAt: 0)) → not a time")
            }
        }
    }

    /// Tick --play <file> plays an audio file once the way the alarm would.
    static func play(_ path: String) {
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(String(format: "%.1f", player.duration)) s, \(player.numberOfChannels) ch")
            player.play()
            Thread.sleep(forTimeInterval: min(player.duration, 4) + 0.2)
        } catch {
            print("can't play: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Tick --snapshot <dir> renders the popover and the alarm card to PNGs (uses a throwaway settings suite).
    @MainActor
    static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PanelBackground.flat = true
        let model = TickModel()
        model.stop()
        func save<V: View>(_ name: String, _ view: V, background: NSColor = NSColor(white: 0.17, alpha: 1)) {
            let hosting = NSHostingView(rootView: view.background(Color(nsColor: background)).environment(\.colorScheme, .dark))
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = background
            window.contentView = hosting
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = dir.appendingPathComponent(name + ".png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            window.orderOut(nil)
            print(url.path)
        }
        save("1-idle", PopoverView(model: model))
        model.input = "25m focus"
        save("2-typing", PopoverView(model: model))
        model.start(25 * 60, label: "focus")
        save("3-running", PopoverView(model: model))
        model.togglePause()
        save("4-paused", PopoverView(model: model))
        model.input = "5 tae kwon"
        model.stop()
        model.input = "lunch"
        model.submit()
        save("5-invalid", PopoverView(model: model))
        model.start(7 * 60, label: "eggs")
        save("6-alarm", AlarmView(model: model).padding(20), background: NSColor(white: 0.45, alpha: 1))
        model.stop()
    }
}

if let i = Test.args.firstIndex(of: "--parse") {
    Test.parse(Test.args[(i + 1)...])
    exit(0)
}
// Tick --add-sound <file> copies a file into the Sounds folder and makes it the alarm, like a drop does.
if let path = Test.value(after: "--add-sound") {
    MainActor.assumeIsolated {
        do { print("added \(try SoundLibrary().add(URL(fileURLWithPath: path)).url.path)") } catch { print("can't add: \(error.localizedDescription)") }
    }
    exit(0)
}
if let path = Test.value(after: "--play") {
    Test.play(path)
    exit(0)
}

// MARK: - Menu bar

/// Sits on top of the status item: click, ⌥-click, right-click, and audio files dropped on it.
final class StatusView: NSView {
    var onClick: (() -> Void)?
    var onOptionClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onAudio: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(); return }
        if event.modifierFlags.contains(.option) { onOptionClick?(); return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    private func audio(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: SoundLibrary.isAudio)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { audio(info) == nil ? [] : .copy }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let url = audio(info) else { return false }
        onAudio?(url)
        return true
    }
}

/// Lets the first click land on what it hits instead of just activating the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AlarmPanel: NSPanel {
    init(model: TickModel) {
        super.init(contentRect: NSRect(origin: .zero, size: AlarmView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FirstClickHostingView(rootView: AlarmView(model: model))
    }

    override var canBecomeKey: Bool { false }
}

/// The idle menu bar icon, picked from the right-click menu.
enum MenuIcon {
    static let choices: [(symbol: String, name: String)] = [
        ("hourglass", "Hourglass"), ("timer", "Timer"), ("stopwatch", "Stopwatch"), ("clock", "Clock"),
        ("alarm", "Alarm Clock"), ("deskclock", "Desk Clock"), ("bell", "Bell"), ("cup.and.saucer", "Cup"),
        ("frying.pan", "Pan"), ("flame", "Flame"), ("leaf", "Leaf"), ("circle.fill", "Dot"),
    ].filter { NSImage(systemSymbolName: $0.0, accessibilityDescription: nil) != nil }

    static var current: String {
        let saved = store.string(forKey: "icon") ?? "hourglass"
        return choices.contains { $0.symbol == saved } ? saved : "hourglass"
    }

    static func image(_ symbol: String) -> NSImage? {
        // The dot is drawn smaller so it sits like a status light rather than a blob.
        let size: CGFloat = symbol == "circle.fill" ? 7 : 13
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tick")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        image?.isTemplate = true
        return image
    }
}

/// System-wide shortcut, no Accessibility permission needed.
enum HotKey {
    nonisolated(unsafe) static var handler: (() -> Void)?

    static func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5449434B), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = TickModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hosting: NSHostingView<PopoverView>!
    private lazy var alarm = AlarmPanel(model: model)
    private var blink: Timer?
    private var outsideClickMonitor: Any?
    /// The app that was in front before the popover opened; it gets focus back after Return or Esc.
    private var previousApp: NSRunningApplication?
    private var contentHeight: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = statusItem.button!
        button.imagePosition = .imageLeading
        let overlay = StatusView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.clicked() }
        overlay.onOptionClick = { [weak self] in self?.model.again() }
        overlay.onRightClick = { [weak self] in self?.showMenu() }
        overlay.onAudio = { [weak self] url in
            guard let self else { return }
            do { try self.model.sounds.add(url) } catch { self.model.sounds.alert("Tick can't play “\(url.lastPathComponent)”.") }
            self.showPopover()
        }
        button.addSubview(overlay)

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        hosting = FirstClickHostingView(rootView: PopoverView(model: model))
        hosting.sizingOptions = []
        let controller = NSViewController()
        controller.view = hosting
        popover.contentViewController = controller
        fitPopover()

        model.onChange = { [weak self] in self?.refresh() }
        model.onStarted = { [weak self] in self?.closePopover(returnFocus: true) }
        model.onEscape = { [weak self] in self?.closePopover(returnFocus: true) }
        model.onHeight = { [weak self] height in
            guard let self, height > 0 else { return }
            self.contentHeight = ceil(height)
            self.fitPopover()
        }
        model.onRing = { [weak self] in self?.showAlarm() }
        model.onRingStopped = { [weak self] in self?.hideAlarm() }
        refresh()

        // ⌃⌥T opens Tick from anywhere (or stops the alarm): type a time, press Return, keep working.
        HotKey.register(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in self?.hotKey() }

        if !store.bool(forKey: "didSetUpLogin"), ProcessInfo.processInfo.environment["TICK_SUITE"] == nil {
            store.set(true, forKey: "didSetUpLogin")
            try? SMAppService.mainApp.register()
        }
        if let text = Test.value(after: "--start"), let r = Parser.parse(text) { model.start(r.seconds, label: r.label) }
        if Test.args.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPopover() } }
        Log.write("Tick started")
        // Tick --log-status logs what the menu bar item shows, once a second for a few seconds.
        if Test.args.contains("--log-status") {
            for i in 1...3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) {
                    let b = self.statusItem.button!
                    Log.write("status: “\(b.attributedTitle.string)” image \(b.image?.name() ?? "-") width \(Int(b.frame.width)) popover \(self.popover.isShown ? "\(Int(self.popover.contentSize.width))x\(Int(self.popover.contentSize.height))" : "closed") icons \(MenuIcon.choices.count) on screen \(b.window?.isVisible == true) at \(b.window.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "-")")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    // MARK: Status item

    private func refresh() {
        guard let button = statusItem?.button else { return }
        // While a timer counts down only the time shows; the icon comes back when it's idle.
        var symbol: String?
        var title = ""
        var paused = false
        switch model.phase {
        case .idle: symbol = MenuIcon.current
        case .running: title = Format.clock(model.remaining)
        case .paused: title = Format.clock(model.remaining); paused = true
        case .ringing: symbol = "bell.fill"; title = "0:00"
        }
        if button.image?.name() != symbol {
            let image = symbol.flatMap { MenuIcon.image($0) }
            image?.setName(symbol)
            button.image = image
        }
        button.imagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .baselineOffset: 0.5,
            .foregroundColor: paused ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if button.attributedTitle != text { button.attributedTitle = text }
        if popover.isShown { fitPopover() }
    }

    private func clicked() {
        if model.phase == .ringing { model.dismiss(); return }
        popover.isShown ? closePopover(returnFocus: true) : showPopover()
    }

    private func hotKey() {
        if model.phase == .ringing { model.dismiss(); return }
        popover.isShown ? closePopover(returnFocus: true) : showPopover()
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        switch model.phase {
        case .ringing:
            add("Stop Alarm", #selector(menuStop))
        case .running, .paused:
            if case .paused = model.phase { add("Resume", #selector(menuPause)) } else { add("Pause", #selector(menuPause)) }
            add("Add 5 Minutes", #selector(menuAddFive))
            add("Stop", #selector(menuStop))
        case .idle:
            if let last = model.last { add("Again: \(last.title)", #selector(menuAgain)) }
        }
        menu.addItem(.separator())
        add("Choose Alarm Sound…", #selector(menuChooseSound))
        let icons = NSMenu()
        for choice in MenuIcon.choices {
            let item = NSMenuItem(title: choice.name, action: #selector(menuIcon(_:)), keyEquivalent: "")
            item.target = self
            item.image = MenuIcon.image(choice.symbol)
            item.representedObject = choice.symbol
            item.state = choice.symbol == MenuIcon.current ? .on : .off
            icons.addItem(item)
        }
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = icons
        menu.addItem(iconItem)
        let shortcut = NSMenuItem(title: "Open Tick: ⌃⌥T   Repeat last: ⌥-click", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Tick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuStop() { model.stop() }
    @objc private func menuPause() { model.togglePause() }
    @objc private func menuAddFive() { model.add(300) }
    @objc private func menuAgain() { model.again() }
    @objc private func menuChooseSound() { model.sounds.choose() }

    @objc private func menuIcon(_ item: NSMenuItem) {
        guard let symbol = item.representedObject as? String else { return }
        store.set(symbol, forKey: "icon")
        refresh()
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    // MARK: Popover

    private func fitPopover() {
        let size = NSSize(width: PopoverView.width, height: contentHeight > 0 ? contentHeight : ceil(hosting.fittingSize.height))
        if popover.contentSize != size {
            hosting.frame = NSRect(origin: .zero, size: size)
            popover.contentSize = size
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        model.invalid = false
        fitPopover()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            if let field = model.field { window.makeFirstResponder(field) }
        }
        // Clicking in another app closes the popover, but not when the press turns into a drag
        // (so an audio file can be dragged from Finder into it).
        var downAt: NSPoint?
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let here = NSEvent.mouseLocation
                switch event.type {
                case .leftMouseDown: downAt = here
                case .leftMouseDragged:
                    if let start = downAt, hypot(here.x - start.x, here.y - start.y) > 4 { downAt = nil }
                case .leftMouseUp:
                    if downAt != nil { self.closePopover(returnFocus: false) }
                    downAt = nil
                default: self.closePopover(returnFocus: false)
                }
            }
        }
    }

    private func closePopover(returnFocus: Bool) {
        guard popover.isShown else { return }
        popover.performClose(nil)
        if returnFocus, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        statusItem.button?.highlight(false)
        model.input = ""
        model.invalid = false
    }

    // MARK: Alarm

    private func showAlarm() {
        closePopover(returnFocus: false)
        let size = AlarmView.size
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = visible.maxX - size.width - 10
        if let frame = statusItem.button?.window?.frame, frame.maxX > visible.minX, frame.minX < visible.maxX {
            x = min(max(frame.maxX - size.width, visible.minX + 10), visible.maxX - size.width - 10)
        }
        alarm.setFrame(NSRect(x: x, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        alarm.alphaValue = 0
        alarm.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; alarm.animator().alphaValue = 1 }
        var on = true
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                on.toggle()
                self?.statusItem.button?.alphaValue = on ? 1 : 0.3
            }
        }
    }

    private func hideAlarm() {
        blink?.invalidate()
        blink = nil
        statusItem.button?.alphaValue = 1
        guard alarm.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; alarm.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated { self?.alarm.orderOut(nil) }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let dir = Test.value(after: "--snapshot") {
        app.setActivationPolicy(.accessory)
        Test.snapshot(to: URL(fileURLWithPath: dir))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
