// PhotoCull – App/AppDelegate.swift

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure required Application Support directory exists
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let photoCullDir = appSupport.appendingPathComponent("PhotoCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: photoCullDir,
                                                 withIntermediateDirectories: true)

        windowController = MainWindowController()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)

        // Re-open last folder automatically
        if let lastPath = UserDefaults.standard.string(forKey: "lastOpenedFolderPath") {
            let url = URL(fileURLWithPath: lastPath)
            windowController?.openFolder(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu actions

    @IBAction func openFolderMenuAction(_ sender: Any) {
        windowController?.promptOpenFolder()
    }
}
