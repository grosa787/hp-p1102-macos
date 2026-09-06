import AppKit
import SwiftUI

extension Notification.Name {
    static let requestOpenPanel = Notification.Name("DuplexHelper.requestOpenPanel")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Created in applicationDidFinishLaunching, which is main-actor isolated;
    // a stored-property initializer would run from the nonisolated init.
    private(set) var model: DuplexModel!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = DuplexModel()
        buildMenu()

        let host = NSHostingView(rootView: ContentView().environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 640)

        window = NSWindow(contentRect: host.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Duplex Helper"
        window.contentView = host
        window.contentMinSize = NSSize(width: 520, height: 600)
        window.setFrameAutosaveName("DuplexHelper.main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in await Snapshot.runIfRequested(model: model, window: window) }
    }

    /// Finder "Open With", or a PDF dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            model.load(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu bar

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Duplex Helper",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Duplex Helper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Duplex Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open PDF…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openDocument(_ sender: Any?) {
        NotificationCenter.default.post(name: .requestOpenPanel, object: nil)
    }
}

/// `Duplex Helper --snapshot DIR [file.pdf]` renders each screen to PNGs in
/// DIR and quits. The app draws itself, so no screen-recording permission is
/// needed. Used for the README images and for checking the UI without a printer.
enum Snapshot {
    @MainActor
    static func runIfRequested(model: DuplexModel, window: NSWindow) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if i + 2 < args.count { model.load(url: URL(fileURLWithPath: args[i + 2])) }

        func snap(_ name: String) async {
            try? await Task.sleep(nanoseconds: 800_000_000)
            // Capture the composited window (SwiftUI draws via CoreAnimation
            // layers, which NSView.cacheDisplay does not include). An app may
            // capture its own windows without screen-recording permission.
            let wid = CGWindowID(window.windowNumber)
            var cg = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.bestResolution])
            if cg == nil, let view = window.contentView {
                // Fallback: render the layer tree directly.
                let scale = window.backingScaleFactor
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0),
                   let gctx = NSGraphicsContext(bitmapImageRep: rep) {
                    gctx.cgContext.scaleBy(x: scale, y: scale)
                    view.layer?.render(in: gctx.cgContext)
                    cg = rep.cgImage
                }
            }
            guard let image = cg else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        await snap("1-setup")
        model.debugSet(phase: .printingOdd(job: "demo-1"))
        await snap("2-printing")
        model.debugSet(phase: .waitingForFlip)
        await snap("3-turn-stack")
        model.debugSet(phase: .done, calibrating: true)
        await snap("4-calibration")
        model.debugSet(phase: .done)
        await snap("5-done")
        NSApp.terminate(nil)
    }
}
