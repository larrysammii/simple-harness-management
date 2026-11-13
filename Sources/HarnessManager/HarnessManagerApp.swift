import AppKit
import SwiftUI
import HarnessCore

@main
struct HarnessManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = "light"
    var body: some Scene {
        Settings {
            PreferencesView(model: delegate.model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "system" ? nil : .light)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add repository…") { delegate.model.addRepository() }.keyboardShortcut("n").disabled(delegate.model.busy)
            }
            CommandMenu("Inventory") {
                Button("Show workspace") { delegate.showWorkspace() }
                Button("Refresh") { NotificationCenter.default.post(name: .refreshInventory, object: nil) }.keyboardShortcut("r").disabled(delegate.model.busy)
                Button("Find resource") { NotificationCenter.default.post(name: .focusInventorySearch, object: nil) }.keyboardShortcut("f")
                Divider()
                Button("Skills") { delegate.model.section = .inventory; delegate.model.kind = .skill }.keyboardShortcut("1")
                Button("MCP servers") { delegate.model.section = .inventory; delegate.model.kind = .mcp }.keyboardShortcut("2")
                Button("Packages") { delegate.model.section = .packages }.keyboardShortcut("3")
                Button("Backups") { delegate.model.section = .backups }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {
                Button("About local discovery") { delegate.model.sheet = .init(content: .warnings) }
            }
        }
    }
}

/// Own the single desktop window explicitly. Its presentation must not depend on
/// SwiftUI WindowGroup restoration deciding to recreate an untitled window.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var workspace: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        showWorkspace()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func showWorkspace() {
        if let workspace { workspace.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 920),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Harness Manager"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 680)
        window.contentView = NSHostingView(rootView: NativeRoot(model: model) { [weak window] appearance in
            window?.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "system" ? nil : NSAppearance(named: .aqua)
        })
        window.center(); window.setFrameAutosaveName("HarnessManager.Workspace")
        workspace = window
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspace() }; return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { try? model.demo?.cleanUp() }
}

private struct NativeRoot: View {
    @Bindable var model: AppModel
    let appearanceChanged: (String) -> Void
    @AppStorage("appearance") private var appearance = "light"
    private var chosenAppearance: String {
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(index + 1) {
            return CommandLine.arguments[index + 1] == "dark" ? "dark" : "light"
        }
        return appearance
    }
    var body: some View {
        WorkspaceView(model: model)
            .preferredColorScheme(chosenAppearance == "dark" ? .dark : chosenAppearance == "system" ? nil : .light)
            .background(WindowCapture(ready: model.hasLoaded && !model.busy, isDemo: model.isDemo))
            .onChange(of: chosenAppearance, initial: true) { _, value in appearanceChanged(value) }
    }
}

private struct PreferencesView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance = "light"
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Light").tag("light"); Text("Dark").tag("dark"); Text("System").tag("system")
                }.pickerStyle(.segmented)
            }
            Section("Local discovery") {
                Text("Configured files are read directly. The app does not start agents, execute package code, connect to servers, or upload inventory.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                ForEach(model.options.scanRoots, id: \.self) { root in Text(FS.friendly(root, home: model.options.home)).font(TypeStyle.mono).textSelection(.enabled) }
                Text("Add a repository from any other location with ⌘N").font(TypeStyle.small).foregroundStyle(Ink.secondary)
            }
            Section("Recovery storage") {
                Text(FS.friendly(model.options.stateDir, home: model.options.home)).font(TypeStyle.mono).textSelection(.enabled)
                Text("Backups may contain credentials from original configuration files. Storage stays private on this Mac.")
                    .font(TypeStyle.small).foregroundStyle(Ink.secondary)
                Button("Reveal app storage") { model.reveal(model.options.stateDir) }
            }
        }.formStyle(.grouped).padding(16).frame(width: 520, height: 440)
    }
}

@MainActor private enum NativeCaptureGate { static var started = false }

/// Capture only a synthetic native window, without screen-recording permission,
/// subprocesses, WebViews, or remote services. Existing output files are never replaced.
private struct WindowCapture: NSViewRepresentable {
    let ready: Bool
    let isDemo: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard ready, isDemo, !NativeCaptureGate.started, !context.coordinator.started,
              let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) else { return }
        NativeCaptureGate.started = true; context.coordinator.started = true
        let path = CommandLine.arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                guard let window = view.window, let content = window.contentView else { throw ManagerError("Native window is not ready") }
                window.displayIfNeeded(); content.layoutSubtreeIfNeeded()
                guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw ManagerError("Native window could not be captured") }
                content.cacheDisplay(in: content.bounds, to: image)
                guard let data = image.representation(using: .png, properties: [:]) else { throw ManagerError("PNG encoding failed") }
                guard path.hasPrefix("/"), !FS.exists(path), !FS.exists(path + ".txt") else { throw ManagerError("Capture requires a new absolute output path") }
                let temporary = FS.join(FS.parent(path), ".harness-capture-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(atPath: temporary) }
                try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
                try FS.moveExclusive(temporary, to: path)
                let receipt = "Native SwiftUI window · \(Int(content.bounds.width))×\(Int(content.bounds.height)) · synthetic data only\n"
                try receipt.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: URL(fileURLWithPath: path + ".error"), options: .withoutOverwriting)
            }
            if CommandLine.arguments.contains("--quit-after-snapshot") { NSApplication.shared.terminate(nil) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var started = false }
}
