// PhotoCull – UI/Detail/DetailViewController.swift
// Full-preview view with filmstrip, HUD overlay, crop mode, keyboard navigation.

import AppKit
import Combine

// MARK: - ZoomMode

enum ZoomMode {
    case fit
    case actual
}

// MARK: - DetailViewController

final class DetailViewController: NSViewController {

    // MARK: - Public

    var currentIndex: Int = 0 {
        didSet { guard isViewLoaded else { return }; loadCurrentPhoto() }
    }
    var onBack: (() -> Void)?

    // MARK: - Dependencies

    private let viewModel: PhotoLibraryViewModel

    // MARK: - Subviews

    private let scrollView  = NSScrollView()
    private let imageView   = NSImageView()
    private var filmstripVC: FilmstripViewController!

    private let backButton  = NSButton()
    private let hudContainer = NSVisualEffectView()
    private var starButtons: [NSButton] = []
    private let flagPickBtn  = NSButton()
    private let flagRejBtn   = NSButton()
    private let flagNoneBtn  = NSButton()
    private var labelDots: [(ColorLabel, NSButton)] = []

    private let zoomButton  = NSButton()
    private let statusBar   = NSVisualEffectView()
    private let filenameLabel   = NSTextField(labelWithString: "")
    private let dateLabel       = NSTextField(labelWithString: "")
    private let dimsLabel       = NSTextField(labelWithString: "")
    private let sizeLabel       = NSTextField(labelWithString: "")

    private let spinner = NSProgressIndicator()
    private var cropOverlay: CropOverlayView?

    // MARK: - State

    private var zoomMode: ZoomMode = .fit
    private var isCropMode = false
    private var imageSize: CGSize = .zero
    private var loadTask: Task<Void, Never>?
    private var spinnerWork: DispatchWorkItem?

    // MARK: - Init

    init(viewModel: PhotoLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupImageArea()
        setupFilmstrip()
        setupStatusBar()
        setupHUD()
        setupBackButton()
        setupZoomButton()
        setupSpinner()
        layoutAll()
        loadCurrentPhoto()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    // MARK: - Setup

    private func setupImageArea() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = imageView
        view.addSubview(scrollView)
    }

    private func setupFilmstrip() {
        filmstripVC = FilmstripViewController(viewModel: viewModel)
        filmstripVC.onSelectIndex = { [weak self] idx in
            self?.currentIndex = idx
        }
        addChild(filmstripVC)
        filmstripVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filmstripVC.view)
    }

    private func setupStatusBar() {
        statusBar.material = .hudWindow
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)
        for lbl in [filenameLabel, dateLabel, dimsLabel, sizeLabel] {
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            lbl.lineBreakMode = .byTruncatingTail
            statusBar.addSubview(lbl)
        }
        filenameLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        filenameLabel.textColor = .labelColor
    }

    private func setupHUD() {
        hudContainer.material = .hudWindow
        hudContainer.blendingMode = .withinWindow
        hudContainer.state = .active
        hudContainer.wantsLayer = true
        hudContainer.layer?.cornerRadius = 10
        hudContainer.layer?.masksToBounds = true
        hudContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudContainer)

        // Stars
        for i in 1...5 {
            let btn = NSButton(title: "★", target: self, action: #selector(starTapped(_:)))
            btn.tag = i; btn.bezelStyle = .rounded; btn.isBordered = false
            btn.font = .systemFont(ofSize: 18, weight: .light)
            btn.contentTintColor = .systemGray
            btn.translatesAutoresizingMaskIntoConstraints = false
            hudContainer.addSubview(btn); starButtons.append(btn)
        }
        // Flags
        for (title, tag, btn) in [("P", 1, flagPickBtn), ("U", 0, flagNoneBtn), ("X", 2, flagRejBtn)] {
            btn.title = title; btn.tag = tag; btn.bezelStyle = .rounded; btn.isBordered = false
            btn.font = .systemFont(ofSize: 13, weight: .medium)
            btn.target = self; btn.action = #selector(flagTapped(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            hudContainer.addSubview(btn)
        }
        // Color dots
        let colors: [(ColorLabel, NSColor)] = [
            (.red, .systemRed), (.yellow, .systemYellow), (.green, .systemGreen),
            (.blue, .systemBlue), (.purple, .systemPurple), (.none, .systemGray)]
        for (i, (lbl, clr)) in colors.enumerated() {
            let btn = NSButton(frame: .zero)
            btn.isBordered = false; btn.wantsLayer = true
            btn.layer?.cornerRadius = 8; btn.layer?.backgroundColor = clr.cgColor
            btn.layer?.borderWidth = 1.5; btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.target = self; btn.action = #selector(labelTapped(_:)); btn.tag = i
            btn.widthAnchor.constraint(equalToConstant: 16).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 16).isActive = true
            hudContainer.addSubview(btn); labelDots.append((lbl, btn))
        }
    }

    private func setupBackButton() {
        backButton.title = "← Grid"; backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.target = self; backButton.action = #selector(backTapped)
        view.addSubview(backButton)
    }

    private func setupZoomButton() {
        zoomButton.title = "Fit"; zoomButton.bezelStyle = .rounded
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.target = self; zoomButton.action = #selector(zoomTapped)
        view.addSubview(zoomButton)
    }

    private func setupSpinner() {
        spinner.style = .spinning; spinner.controlSize = .regular
        spinner.isIndeterminate = true; spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
    }

    // MARK: - Layout

    private func layoutAll() {
        let fH: CGFloat = 100, sH: CGFloat = 28

        NSLayoutConstraint.activate([
            // Filmstrip at bottom
            filmstripVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstripVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstripVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            filmstripVC.view.heightAnchor.constraint(equalToConstant: fH),
            // Status bar above filmstrip
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: filmstripVC.view.topAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: sH),
            // Scroll view fills above status bar
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            // Image fills scroll clip view
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            // Back button
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            backButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 90),
            backButton.heightAnchor.constraint(equalToConstant: 30),
            // HUD top-right
            hudContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            hudContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            hudContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            // Zoom button
            zoomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            zoomButton.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -8),
            zoomButton.widthAnchor.constraint(equalToConstant: 76),
            // Spinner
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        // Status bar labels
        NSLayoutConstraint.activate([
            filenameLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            filenameLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            filenameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            dateLabel.leadingAnchor.constraint(equalTo: filenameLabel.trailingAnchor, constant: 16),
            dateLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            dimsLabel.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 16),
            dimsLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: dimsLabel.trailingAnchor, constant: 16),
            sizeLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        layoutHUD()
    }

    private func layoutHUD() {
        let pad: CGFloat = 10, starSz: CGFloat = 24, sp: CGFloat = 4, flagSz: CGFloat = 24
        var cons: [NSLayoutConstraint] = []
        // Stars row
        var prevTrail = hudContainer.leadingAnchor
        for (i, btn) in starButtons.enumerated() {
            cons += [
                btn.leadingAnchor.constraint(equalTo: prevTrail, constant: i == 0 ? pad : sp),
                btn.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: pad),
                btn.widthAnchor.constraint(equalToConstant: starSz),
                btn.heightAnchor.constraint(equalToConstant: starSz)]
            prevTrail = btn.trailingAnchor
        }
        if let last = starButtons.last {
            cons.append(last.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -pad))
        }
        // Flags row
        let flagBtns = [flagPickBtn, flagNoneBtn, flagRejBtn]
        prevTrail = hudContainer.leadingAnchor
        for (i, btn) in flagBtns.enumerated() {
            cons += [
                btn.leadingAnchor.constraint(equalTo: prevTrail, constant: i == 0 ? pad : sp),
                btn.topAnchor.constraint(equalTo: starButtons[0].bottomAnchor, constant: sp),
                btn.widthAnchor.constraint(equalToConstant: flagSz),
                btn.heightAnchor.constraint(equalToConstant: flagSz)]
            prevTrail = btn.trailingAnchor
        }
        // Dots row
        prevTrail = hudContainer.leadingAnchor
        for (i, (_, btn)) in labelDots.enumerated() {
            cons += [
                btn.leadingAnchor.constraint(equalTo: prevTrail, constant: i == 0 ? pad : 6),
                btn.topAnchor.constraint(equalTo: flagPickBtn.bottomAnchor, constant: sp)]
            prevTrail = btn.trailingAnchor
        }
        if let (_, last) = labelDots.last {
            cons.append(last.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -pad))
        }
        NSLayoutConstraint.activate(cons)
    }

    // MARK: - Photo Loading

    private func loadCurrentPhoto() {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        let idx = max(0, min(currentIndex, photos.count - 1))
        let item = photos[idx]

        loadTask?.cancel()
        spinnerWork?.cancel()
        spinner.stopAnimation(nil); spinner.isHidden = true
        imageView.image = nil

        // Preload nearby images
        Task { await preloadWindow(center: idx) }

        // Deferred spinner
        let work = DispatchWorkItem { [weak self] in
            self?.spinner.isHidden = false
            self?.spinner.startAnimation(nil)
        }
        spinnerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)

        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let image = await viewModel.imageService.loadFullRes(for: item) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.spinnerWork?.cancel()
                self.spinner.stopAnimation(nil); self.spinner.isHidden = true
                self.imageView.image = image
                self.imageSize = image.size
                self.updateHUD(for: item)
                self.updateStatusBar(for: item)
                self.filmstripVC.currentIndex = idx
            }
        }
    }

    private func preloadWindow(center: Int) async {
        let items = viewModel.filteredPhotos
        let lo = max(0, center - 2), hi = min(items.count - 1, center + 5)
        guard lo <= hi else { return }
        await withTaskGroup(of: Void.self) { group in
            for i in lo...hi where i != center {
                let item = items[i]
                group.addTask { [weak self] in
                    _ = await self?.viewModel.imageService.loadFullRes(for: item)
                }
            }
        }
    }

    // MARK: - HUD Update

    private func updateHUD(for item: PhotoItem) {
        for (i, btn) in starButtons.enumerated() {
            btn.contentTintColor = (i + 1 <= item.rating.rawValue) ? .systemYellow : .systemGray
        }
        flagPickBtn.contentTintColor = item.flag == .picked ? .systemGreen : .secondaryLabelColor
        flagRejBtn.contentTintColor = item.flag == .rejected ? .systemRed : .secondaryLabelColor
        flagNoneBtn.contentTintColor = item.flag == .unflagged ? .labelColor : .secondaryLabelColor
        for (lbl, btn) in labelDots {
            let active = item.label == lbl
            btn.layer?.borderColor = active ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.3).cgColor
            btn.layer?.borderWidth = active ? 2.5 : 1.5
        }
    }

    private func updateStatusBar(for item: PhotoItem) {
        filenameLabel.stringValue = item.filename
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        dateLabel.stringValue = df.string(from: item.displayDate)
        dimsLabel.stringValue = imageSize != .zero ? "\(Int(imageSize.width)) × \(Int(imageSize.height))" : ""
        let b = item.fileSize
        sizeLabel.stringValue = b >= 1_048_576 ? String(format: "%.1f MB", Double(b)/1_048_576)
            : b >= 1024 ? String(format: "%.0f KB", Double(b)/1024) : "\(b) B"
    }

    // MARK: - Navigation

    func goNext() {
        guard !viewModel.filteredPhotos.isEmpty else { return }
        currentIndex = (currentIndex + 1) % viewModel.filteredPhotos.count
    }
    func goPrev() {
        guard !viewModel.filteredPhotos.isEmpty else { return }
        let c = viewModel.filteredPhotos.count
        currentIndex = (currentIndex - 1 + c) % c
    }

    private var currentItem: PhotoItem? {
        let ps = viewModel.filteredPhotos
        guard !ps.isEmpty else { return nil }
        return ps[max(0, min(currentIndex, ps.count - 1))]
    }

    // MARK: - Zoom

    private func toggleZoom() {
        zoomMode = (zoomMode == .fit) ? .actual : .fit
        applyZoom()
    }

    private func applyZoom() {
        for c in imageView.constraints { imageView.removeConstraint(c) }
        switch zoomMode {
        case .fit:
            zoomButton.title = "Fit"
            imageView.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor)])
        case .actual:
            zoomButton.title = "100%"
            imageView.imageScaling = .scaleNone
            if imageSize != .zero {
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: imageSize.width),
                    imageView.heightAnchor.constraint(equalToConstant: imageSize.height)])
            }
        }
    }

    // MARK: - Crop Mode

    private func toggleCropMode() {
        isCropMode ? exitCrop(save: false) : enterCrop()
    }

    private func enterCrop() {
        guard cropOverlay == nil else { return }
        isCropMode = true
        let overlay = CropOverlayView(frame: imageView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.imageDisplayRect = imageView.bounds
        if let existing = currentItem?.cropRect {
            overlay.cropRect = existing.cgRect
        }
        imageView.addSubview(overlay)
        cropOverlay = overlay
    }

    private func exitCrop(save: Bool) {
        isCropMode = false
        if save, let overlay = cropOverlay, let item = currentItem {
            let cg = overlay.cropRect
            let rect = CropRect(cgRect: cg, aspect: overlay.aspectPreset)
            viewModel.setCrop(rect, for: item)
        }
        cropOverlay?.removeFromSuperview()
        cropOverlay = nil
    }

    // MARK: - Actions

    @objc private func backTapped() { onBack?() }
    @objc private func zoomTapped() { toggleZoom() }

    @objc private func starTapped(_ sender: NSButton) {
        guard let item = currentItem else { return }
        viewModel.setRating(StarRating(rawValue: sender.tag) ?? .unrated, for: item)
        refreshHUD()
    }

    @objc private func flagTapped(_ sender: NSButton) {
        guard let item = currentItem else { return }
        let f: FlagStatus = sender.tag == 1 ? .picked : sender.tag == 2 ? .rejected : .unflagged
        viewModel.setFlag(f, for: item)
        refreshHUD()
    }

    @objc private func labelTapped(_ sender: NSButton) {
        guard let item = currentItem, sender.tag < labelDots.count else { return }
        viewModel.setLabel(labelDots[sender.tag].0, for: item)
        refreshHUD()
    }

    private func refreshHUD() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.updateHUD(for: item)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let flags = event.modifierFlags

        // Cmd shortcuts
        if flags.contains(.command) {
            switch chars {
            case "r":
                if let item = currentItem {
                    NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
                }
                return
            case "e":
                exportPicked()
                return
            default: break
            }
        }

        switch event.keyCode {
        case 123: if !isCropMode { goPrev() }; return
        case 124: if !isCropMode { goNext() }; return
        case 53: // Escape
            if isCropMode { exitCrop(save: false) } else { onBack?() }; return
        case 36: // Return
            if isCropMode { exitCrop(save: true) }; return
        default: break
        }

        guard let item = currentItem else { super.keyDown(with: event); return }

        if let c = chars.first {
            // In crop mode, number keys control aspect ratio
            if isCropMode {
                switch c {
                case "f", "F": cropOverlay?.setAspect(.free); return
                case "1": cropOverlay?.setAspect(.square); return
                case "2": cropOverlay?.setAspect(.portrait); return
                case "3": cropOverlay?.setAspect(.wide); return
                case "0": cropOverlay?.resetToFull(); return
                default: break
                }
            }

            switch c {
            case "1": viewModel.setRating(.one, for: item); refreshHUD(); return
            case "2": viewModel.setRating(.two, for: item); refreshHUD(); return
            case "3": viewModel.setRating(.three, for: item); refreshHUD(); return
            case "4": viewModel.setRating(.four, for: item); refreshHUD(); return
            case "5": viewModel.setRating(.five, for: item); refreshHUD(); return
            case "0": viewModel.setRating(.unrated, for: item); refreshHUD(); return
            case "p", "P": viewModel.setFlag(.picked, for: item); refreshHUD(); return
            case "x", "X": viewModel.setFlag(.rejected, for: item); refreshHUD(); return
            case "u", "U": viewModel.setFlag(.unflagged, for: item); refreshHUD(); return
            case "6": viewModel.setLabel(.red, for: item); refreshHUD(); return
            case "7": viewModel.setLabel(.yellow, for: item); refreshHUD(); return
            case "8": viewModel.setLabel(.green, for: item); refreshHUD(); return
            case "9": viewModel.setLabel(.blue, for: item); refreshHUD(); return
            case "z", "Z": toggleZoom(); return
            case "c", "C": toggleCropMode(); return
            case "?":
                if let win = view.window {
                    let sheet = KeyboardShortcutsSheet()
                    sheet.present(relativeTo: win)
                }
                return
            default: break
            }
        }

        super.keyDown(with: event)
    }

    private func exportPicked() {
        let picked = viewModel.pickedItems()
        guard !picked.isEmpty, let window = view.window else { return }
        Task {
            guard let dest = await viewModel.exportService.showDestinationPicker(in: window) else { return }
            try? await viewModel.exportService.copyFiles(picked, to: dest, cropMode: .originalFile) { progress in
                // Could show progress indicator
            }
        }
    }
}

