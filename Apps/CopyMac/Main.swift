import SwiftUI
import AppKit
import CopyCore
import CopyStorage

@main struct CopyApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { SettingsRoot(delegate:delegate) } }
}

struct SettingsRoot: View {
    @ObservedObject var delegate: AppDelegate
    var body: some View { if let model = delegate.model { SettingsView(model:model) } else { ProgressView("正在打开资料库…").padding(30) } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published var model: AppModel?
    private var statusItem: NSStatusItem?
    private var library: NSWindow?
    private var panel: NSPanel?
    private var preferences: NSWindow?
    private var monitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let uiTest = CommandLine.arguments.contains("--ui-test") || Bundle.main.bundleIdentifier == "dev.neo.Copy.UITest"
            if !uiTest { LibraryLocation.activatePending() }
            let root = uiTest ? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ui-test-library") : nil
            let model = try AppModel(root:root,uiTest:uiTest); self.model = model
            model.showPanel = { [weak self] in self?.togglePanel() }
            model.hidePanel = { [weak self] in self?.closePanel() }
            model.showLibrary = { [weak self] in self?.openLibrary() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); statusItem = item
            item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy 剪贴板")
            let menu = NSMenu()
            menu.addItem(withTitle: "打开快捷面板", action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: "打开资料库", action: #selector(openLibrary), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "暂停 / 恢复采集", action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(withTitle: "演示保护", action: #selector(toggleConceal), keyEquivalent: "")
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(NSMenuItem.separator()); menu.addItem(withTitle: "退出 Copy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) { entry.target = self }; item.menu = menu
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKey(event) ?? event }
            if uiTest || !model.settings.captureEnabled { openLibrary() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法打开 Copy 资料库"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    @objc func openLibrary() {
        guard let model else { return }
        if library == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Copy · 资料库"; window.minSize = NSSize(width: 800, height: 480); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LibraryView(model: model)); window.center(); library = window
        }
        NSApp.activate(ignoringOtherApps: true); library?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePanel() {
        guard let model else { return }
        if panel?.isVisible == true { closePanel(); return }
        model.target = NSWorkspace.shared.frontmostApplication
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Copy"; window.titleVisibility = .hidden; window.level = .floating; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; window.hidesOnDeactivate = true; window.delegate = self
            window.contentView = NSHostingView(rootView: QuickPanel(model: model)); panel = window
        }
        model.query = ""; model.selection = []; model.collectionID = nil; model.kind = nil; model.dateFilter = 0; model.sourceFilter = ""; model.reload(); model.panelVisible = true; model.panelGeneration += 1
        let pointer = NSEvent.mouseLocation, screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame, let panel { panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2)) }
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
    }
    func closePanel() { panel?.orderOut(nil); model?.panelVisible = false }
    func windowWillClose(_ notification: Notification) { if (notification.object as? NSWindow) == panel { model?.panelVisible = false } }
    func windowDidResignKey(_ notification: Notification) { if (notification.object as? NSWindow) == panel, panel?.attachedSheet == nil { closePanel() } }
    @objc func togglePause() { model?.settings.pausedManually.toggle(); model?.saveSettings() }
    @objc func toggleConceal() { model?.settings.conceal.toggle(); model?.saveSettings() }
    @objc func openSettings() {
        guard let model else { return }
        if preferences == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 670), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Copy · 设置"; window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center(); preferences = window
        }
        NSApp.activate(ignoringOtherApps: true); preferences?.makeKeyAndOrderFront(nil)
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true, let model else { return event }
        // While composing, Escape/Return/arrows belong to the input method.
        if let client = panel?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return event }
        if event.keyCode == 53 { closePanel(); return nil }
        guard !model.settings.conceal else { return event }
        if event.modifierFlags.contains(.command), let character = event.charactersIgnoringModifiers, let index = Int(character), (1...9).contains(index), model.items.indices.contains(index - 1) {
            model.copy([model.items[index - 1]], paste: true); return nil
        }
        if [125,126].contains(event.keyCode), !model.items.isEmpty {
            let current = model.items.firstIndex(where: { model.selection.contains($0.id) }) ?? (event.keyCode == 125 ? -1 : model.items.count)
            let next = min(model.items.count-1,max(0,current + (event.keyCode == 125 ? 1 : -1)))
            model.selection = [model.items[next].id]; return nil
        }
        if event.keyCode == 36, model.selection.isEmpty, let first = model.items.first { model.selection = [first.id] }
        if event.keyCode == 36, !model.selection.isEmpty { model.copySelected(plain: event.modifierFlags.contains(.shift), paste: true); return nil }
        return event
    }
    func applicationWillTerminate(_ notification: Notification) { model?.clipboard.stop(); model?.pauseQueue() }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "copy", let id = UUID(uuidString:url.lastPathComponent), let model, !model.settings.conceal else { return }
        do {
            if url.host == "collection", try model.store.collections().contains(where:{ $0.id == id }) { openLibrary(); model.collectionID = id }
            else if url.host == "item", try model.store.item(id) != nil { openLibrary(); model.focusItem(id) }
        } catch { model.error = error.localizedDescription }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard let raw = userActivity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String, UUID(uuidString:raw) != nil, let url = URL(string:"copy://item/\(raw)") else { return false }
        self.application(application,open:[url]); return true
    }
}
