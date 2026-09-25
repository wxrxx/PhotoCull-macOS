// PhotoCull – App/MainWindowController.swift
// Owns the split-pane window: toolbar + content area that switches between Grid and Detail.

import AppKit

final class MainWindowController: NSWindowController {

    // MARK: - Child VCs
    private(set) var gridVC: GridViewController!
    private(set) var detailVC: DetailViewController!
    private(set) var filterBar: FilterToolbarController!

    // MARK: - Shared ViewModel (injected into all child VCs)
    let viewModel: PhotoLibraryViewModel = PhotoLibraryViewModel()

    // MARK: - View mode
    enum ViewMode { case grid, detail }
    private(set) var currentMode: ViewMode = .grid

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PhotoCull"
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("MainWindow")
        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let window = window else { return }

        // Build child view controllers
        gridVC   = GridViewController(viewModel: viewModel)
        detailVC = DetailViewController(viewModel: viewModel)
        
        filterBar = FilterToolbarController()
        filterBar.viewModel = viewModel
        filterBar.setup(for: window) // This attaches the toolbar to the window

        // Wire navigation callbacks
        gridVC.onOpenDetail = { [weak self] index in
            self?.switchToDetail(startIndex: index)
        }
        detailVC.onBack = { [weak self] in
            self?.switchToGrid()
        }

        // Container view
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container

        // Start with grid
        install(childVC: gridVC, into: container)

        // Global key handler: '?' for cheat-sheet, Cmd+O for open folder
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleGlobalKey(event) ?? event
        }
    }

    // MARK: - View Mode Switching

    func switchToDetail(startIndex: Int) {
        guard currentMode != .detail else { return }
        currentMode = .detail

        detailVC.currentIndex = startIndex
        transition(to: detailVC)
        window?.makeFirstResponder(detailVC.view)
    }

    func switchToGrid() {
        guard currentMode != .grid else { return }
        currentMode = .grid
        transition(to: gridVC)
        window?.makeFirstResponder(gridVC.view)
    }

    private func transition(to newVC: NSViewController) {
        guard let container = window?.contentView else { return }

        // Remove all existing children
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        install(childVC: newVC, into: container)
    }

    private func install(childVC: NSViewController, into parent: NSView) {
        addChild(childVC)
        parent.addSubview(childVC.view)
        childVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            childVC.view.topAnchor.constraint(equalTo: parent.topAnchor),
            childVC.view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            childVC.view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            childVC.view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    // MARK: - Folder opening

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of photos to cull"
        panel.prompt = "Open"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.openFolder(url)
            }
        }
    }

    func openFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "lastOpenedFolderPath")
        window?.title = "PhotoCull – \(url.lastPathComponent)"
        switchToGrid()
        Task { @MainActor in
            await viewModel.openFolder(url)
        }
    }

    // MARK: - Global Key Handler

    private func handleGlobalKey(_ event: NSEvent) -> NSEvent? {
        // Handle Cmd shortcuts
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "o" {
                promptOpenFolder()
                return nil
            }
            return event
        }
        
        // Handle standalone keys
        switch event.charactersIgnoringModifiers {
        case "?":
            showKeyboardShortcuts()
            return nil
        default:
            return event
        }
    }

    private func showKeyboardShortcuts() {
        let sheet = KeyboardShortcutsSheet()
        sheet.present(relativeTo: window)
    }
}
