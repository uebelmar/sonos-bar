import AppKit
import ServiceManagement
import SwiftUI

/// Menu bar item: left click toggles the popover, right click shows a menu.
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = SonosStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "Sonos")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        handleLaunchArguments()   // before the content view reads "initialTab"
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

        Task { await store.connect() }
    }

    /// `--register-login-item`: enable "start at login" without opening the menu
    /// (used by the install script). `--show-popover [--tab <name>]`: open the
    /// popover right away and print its window number — for README screenshots.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--register-login-item"), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
            UserDefaults.standard.set(args[i + 1], forKey: "initialTab")
        } else {
            UserDefaults.standard.removeObject(forKey: "initialTab")
        }
        if args.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.togglePopover()
                if let number = self?.popover.contentViewController?.view.window?.windowNumber {
                    print("popover-window \(number)")
                    fflush(stdout)
                }
            }
        }
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func popoverWillShow(_ notification: Notification) {
        store.startPolling()
        Task { await store.loadLibrary() }
    }

    public func popoverDidClose(_ notification: Notification) {
        store.stopPolling()
    }

    // MARK: Context menu

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let rescan = NSMenuItem(title: "Neu verbinden", action: #selector(reconnect), keyEquivalent: "r")
        rescan.target = self
        menu.addItem(rescan)

        let login = NSMenuItem(title: "Beim Anmelden starten", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func reconnect() {
        UserDefaults.standard.removeObject(forKey: "lastHost")
        Task { await store.connect() }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            store.errorMessage = "Autostart: \(error.localizedDescription)"
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
