// PhotoCull – UI/Toolbar/FilterToolbarController.swift
// Main window toolbar handling filtering, sorting, and export menu.

import AppKit
import Combine

final class FilterToolbarController: NSObject, NSToolbarDelegate {

    // MARK: - Properties

    weak var viewModel: PhotoLibraryViewModel?
    weak var window: NSWindow?

    private var cancellables = Set<AnyCancellable>()

    // UI Controls
    private let flagSegment = NSSegmentedControl()
    private let ratingSegment = NSSegmentedControl()
    private let sortPopup = NSPopUpButton()

    // MARK: - Identifiers

    private struct Identifiers {
        static let openFolder = NSToolbarItem.Identifier("OpenFolder")
        static let flagFilter = NSToolbarItem.Identifier("FlagFilter")
        static let ratingFilter = NSToolbarItem.Identifier("RatingFilter")
        static let sortOrder = NSToolbarItem.Identifier("SortOrder")
        static let exportMenu = NSToolbarItem.Identifier("ExportMenu")
    }

    // MARK: - Setup

    func setup(for window: NSWindow) {
        self.window = window
        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        setupControls()
        bindViewModel()
    }

    private func setupControls() {
        // Flag filter: All, Pick, Reject, Unflagged
        flagSegment.segmentCount = 4
        flagSegment.setLabel("All", forSegment: 0)
        flagSegment.setLabel("⚑ Pick", forSegment: 1)
        flagSegment.setLabel("✗ Reject", forSegment: 2)
        flagSegment.setLabel("Unflagged", forSegment: 3)
        flagSegment.trackingMode = .selectOne
        flagSegment.target = self
        flagSegment.action = #selector(flagChanged)

        // Rating filter: ★0+, ★1+, ★2+, ★3+, ★4+, ★5
        ratingSegment.segmentCount = 6
        for i in 0...5 { ratingSegment.setLabel("★\(i)+", forSegment: i) }
        if let last = ratingSegment.label(forSegment: 5) { ratingSegment.setLabel(String(last.dropLast()), forSegment: 5) }
        ratingSegment.trackingMode = .selectOne
        ratingSegment.target = self
        ratingSegment.action = #selector(ratingChanged)

        // Sort order
        sortPopup.addItems(withTitles: [
            "Sort: Filename", "Sort: Date Taken", "Sort: Rating", "Sort: Flag"
        ])
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
    }

    private func bindViewModel() {
        guard let vm = viewModel else { return }

        vm.$filterState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state.showOnlyFlag {
                case nil: self.flagSegment.selectedSegment = 0
                case .picked: self.flagSegment.selectedSegment = 1
                case .rejected: self.flagSegment.selectedSegment = 2
                case .unflagged: self.flagSegment.selectedSegment = 3
                }
                self.ratingSegment.selectedSegment = state.minRating.rawValue
            }
            .store(in: &cancellables)

        vm.$sortOrder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] order in
                guard let self else { return }
                switch order {
                case .filename: self.sortPopup.selectItem(at: 0)
                case .dateTaken: self.sortPopup.selectItem(at: 1)
                case .rating: self.sortPopup.selectItem(at: 2)
                case .flag: self.sortPopup.selectItem(at: 3)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func openFolderTapped() {
        // App logic handled by MainWindowController, but we can emit a Notification or call it
        guard let win = window,
              let wc = win.windowController as? MainWindowController else { return }
        wc.promptOpenFolder()
    }

    @objc private func flagChanged() {
        guard let vm = viewModel else { return }
        var state = vm.filterState
        switch flagSegment.selectedSegment {
        case 1: state.showOnlyFlag = .picked
        case 2: state.showOnlyFlag = .rejected
        case 3: state.showOnlyFlag = .unflagged
        default: state.showOnlyFlag = nil
        }
        vm.filterState = state
    }

    @objc private func ratingChanged() {
        guard let vm = viewModel else { return }
        var state = vm.filterState
        state.minRating = StarRating(rawValue: ratingSegment.selectedSegment) ?? .unrated
        vm.filterState = state
    }

    @objc private func sortChanged() {
        guard let vm = viewModel else { return }
        switch sortPopup.indexOfSelectedItem {
        case 0: vm.sortOrder = .filename
        case 1: vm.sortOrder = .dateTaken
        case 2: vm.sortOrder = .rating
        case 3: vm.sortOrder = .flag
        default: break
        }
    }

    @objc private func exportReveal() {
        guard let vm = viewModel else { return }
        Task { await vm.exportService.revealInFinder(vm.pickedItems()) }
    }

    @objc private func exportCopyPicks() {
        guard let vm = viewModel, let win = window else { return }
        let picks = vm.pickedItems()
        guard !picks.isEmpty else { return }

        Task {
            if let dest = await vm.exportService.showDestinationPicker(in: win) {
                try? await vm.exportService.copyFiles(picks, to: dest, cropMode: .originalFile, progress: { _ in })
            }
        }
    }

    @objc private func exportOpenWith() {
        guard let vm = viewModel, let win = window else { return }
        let picks = vm.pickedItems()
        guard !picks.isEmpty else { return }
        Task { await vm.exportService.showOpenWithPicker(for: picks, in: win) }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            Identifiers.openFolder,
            .flexibleSpace,
            Identifiers.flagFilter,
            Identifiers.ratingFilter,
            Identifiers.sortOrder,
            .flexibleSpace,
            Identifiers.exportMenu
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        switch itemIdentifier {
        case Identifiers.openFolder:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open Folder"
            item.toolTip = "Open Folder containing photos"
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "folder.open", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(openFolderTapped)
            return item

        case Identifiers.flagFilter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter Flag"
            item.view = flagSegment
            return item

        case Identifiers.ratingFilter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter Rating"
            item.view = ratingSegment
            return item

        case Identifiers.sortOrder:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sort Order"
            item.view = sortPopup
            return item

        case Identifiers.exportMenu:
            let menu = NSMenu(title: "Export")
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(exportReveal), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Copy Picks to Folder...", action: #selector(exportCopyPicks), keyEquivalent: "e").target = self
            menu.addItem(withTitle: "Open Picks With...", action: #selector(exportOpenWith), keyEquivalent: "O").target = self

            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            item.menu = menu
            return item

        default:
            return nil
        }
    }
}
