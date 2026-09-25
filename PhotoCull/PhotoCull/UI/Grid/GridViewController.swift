// PhotoCull – UI/Grid/GridViewController.swift
// NSCollectionView-based thumbnail grid browser.

import AppKit
import Combine

final class GridViewController: NSViewController {

    // MARK: - Public

    var onOpenDetail: ((Int) -> Void)?

    // MARK: - Private

    private let viewModel: PhotoLibraryViewModel
    private var cancellables = Set<AnyCancellable>()

    private var thumbnailSize: CGFloat = 200 {
        didSet {
            guard thumbnailSize != oldValue else { return }
            flowLayout.itemSize = NSSize(width: thumbnailSize, height: thumbnailSize)
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.reloadData()
        }
    }

    // MARK: - UI Components

    private lazy var flowLayout: NSCollectionViewFlowLayout = {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: thumbnailSize, height: thumbnailSize)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return layout
    }()

    private lazy var collectionView: NSCollectionView = {
        let cv = NSCollectionView()
        cv.collectionViewLayout = flowLayout
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        cv.isPrefetchingEnabled = true
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.backgroundColors = [.controlBackgroundColor]
        cv.register(ThumbnailCell.self,
                    forItemWithIdentifier: NSUserInterfaceItemIdentifier("ThumbnailCell"))
        return cv
    }()

    private lazy var scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.documentView = collectionView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var sizeSlider: NSSlider = {
        let s = NSSlider()
        s.minValue = 80; s.maxValue = 320; s.doubleValue = Double(thumbnailSize)
        s.isContinuous = true; s.target = self; s.action = #selector(sliderChanged(_:))
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        return s
    }()

    private lazy var statusLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return l
    }()

    // MARK: - Init

    init(viewModel: PhotoLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        bindViewModel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: - Layout

    private func setupLayout() {
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let minusBtn = NSButton(title: "−", target: self, action: #selector(decSize))
        minusBtn.bezelStyle = .rounded
        minusBtn.translatesAutoresizingMaskIntoConstraints = false

        let plusBtn = NSButton(title: "+", target: self, action: #selector(incSize))
        plusBtn.bezelStyle = .rounded
        plusBtn.translatesAutoresizingMaskIntoConstraints = false

        bottomBar.addSubview(statusLabel)
        bottomBar.addSubview(minusBtn)
        bottomBar.addSubview(sizeSlider)
        bottomBar.addSubview(plusBtn)

        view.addSubview(scrollView)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            minusBtn.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),
            minusBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            sizeSlider.leadingAnchor.constraint(equalTo: minusBtn.trailingAnchor, constant: 4),
            sizeSlider.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            plusBtn.leadingAnchor.constraint(equalTo: sizeSlider.trailingAnchor, constant: 4),
            plusBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
            plusBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
    }

    // MARK: - Combine

    private func bindViewModel() {
        viewModel.$filteredPhotos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.collectionView.reloadData()
                self?.updateStatus()
            }
            .store(in: &cancellables)

        viewModel.$selectedIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSelection() }
            .store(in: &cancellables)
    }

    private func updateStatus() {
        let f = viewModel.filteredPhotos.count
        let t = viewModel.allPhotosCount
        statusLabel.stringValue = (f == t) ? "\(f) photo\(f == 1 ? "" : "s")" : "\(f) of \(t) photos"
    }

    private func syncSelection() {
        let photos = viewModel.filteredPhotos
        var paths = Set<IndexPath>()
        for (i, p) in photos.enumerated() {
            if let id = p.id, viewModel.selectedIDs.contains(id) {
                paths.insert(IndexPath(item: i, section: 0))
            }
        }
        guard collectionView.selectionIndexPaths != paths else { return }
        collectionView.selectionIndexPaths = paths
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ s: NSSlider) { thumbnailSize = CGFloat(s.doubleValue) }
    @objc private func decSize() { let v = max(80, thumbnailSize - 20); thumbnailSize = v; sizeSlider.doubleValue = Double(v) }
    @objc private func incSize() { let v = min(320, thumbnailSize + 20); thumbnailSize = v; sizeSlider.doubleValue = Double(v) }

    private func photo(at ip: IndexPath) -> PhotoItem? {
        let ps = viewModel.filteredPhotos
        guard ip.item >= 0, ip.item < ps.count else { return nil }
        return ps[ip.item]
    }

    // MARK: - Arrow Navigation

    private func moveSelection(by delta: (col: Int, row: Int)) {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        let selected = collectionView.selectionIndexPaths
        let anchor = selected.min(by: { $0.item < $1.item })?.item ?? 0
        let cols = columnsInLayout()
        let newIdx = (anchor / cols + delta.row) * cols + (anchor % cols + delta.col)
        guard newIdx >= 0, newIdx < photos.count else { return }
        if let id = photos[newIdx].id { viewModel.selectedIDs = [id] }
        collectionView.scrollToItems(at: [IndexPath(item: newIdx, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    private func columnsInLayout() -> Int {
        let w = collectionView.bounds.width - flowLayout.sectionInset.left - flowLayout.sectionInset.right
        max(1, Int((w + flowLayout.minimumInteritemSpacing) / (flowLayout.itemSize.width + flowLayout.minimumInteritemSpacing)))
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { super.keyDown(with: event); return }

        // Cmd+A
        if event.modifierFlags.contains(.command), chars == "a" {
            viewModel.selectedIDs = Set(photos.compactMap(\.id))
            return
        }

        // Arrow keys
        switch event.keyCode {
        case 123: moveSelection(by: (col: -1, row: 0)); return
        case 124: moveSelection(by: (col: +1, row: 0)); return
        case 125: moveSelection(by: (col: 0, row: +1)); return
        case 126: moveSelection(by: (col: 0, row: -1)); return
        default: break
        }

        // Enter/Space → open detail
        if event.keyCode == 36 || event.keyCode == 49 {
            if let id = viewModel.selectedIDs.first,
               let idx = photos.firstIndex(where: { $0.id == id }) {
                onOpenDetail?(idx)
            }
            return
        }

        // Single selected item for rating/flag
        let sel: PhotoItem? = {
            guard viewModel.selectedIDs.count == 1, let id = viewModel.selectedIDs.first else { return nil }
            return photos.first { $0.id == id }
        }()

        if let c = chars.first, let item = sel {
            switch c {
            case "1": viewModel.setRating(.one, for: item); return
            case "2": viewModel.setRating(.two, for: item); return
            case "3": viewModel.setRating(.three, for: item); return
            case "4": viewModel.setRating(.four, for: item); return
            case "5": viewModel.setRating(.five, for: item); return
            case "0": viewModel.setRating(.unrated, for: item); return
            case "p", "P": viewModel.setFlag(.picked, for: item); return
            case "x", "X": viewModel.setFlag(.rejected, for: item); return
            case "u", "U": viewModel.setFlag(.unflagged, for: item); return
            case "6": viewModel.setLabel(.red, for: item); return
            case "7": viewModel.setLabel(.yellow, for: item); return
            case "8": viewModel.setLabel(.green, for: item); return
            case "9": viewModel.setLabel(.blue, for: item); return
            default: break
            }
        }

        super.keyDown(with: event)
    }
}

// MARK: - NSCollectionViewDataSource

extension GridViewController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        viewModel.filteredPhotos.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: NSUserInterfaceItemIdentifier("ThumbnailCell"), for: indexPath)
        if let cell = item as? ThumbnailCell, let p = photo(at: indexPath) {
            cell.configure(with: p, thumbnailSize: thumbnailSize, imageService: viewModel.imageService)
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension GridViewController: NSCollectionViewDelegate {
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        viewModel.selectedIDs = Set(cv.selectionIndexPaths.compactMap { photo(at: $0)?.id })
    }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        viewModel.selectedIDs = Set(cv.selectionIndexPaths.compactMap { photo(at: $0)?.id })
    }
}

// MARK: - NSCollectionViewPrefetching

extension GridViewController: NSCollectionViewPrefetching {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let photos = viewModel.filteredPhotos
        let items = indexPaths.compactMap { ip -> PhotoItem? in
            guard ip.item < photos.count else { return nil }
            return photos[ip.item]
        }
        guard !items.isEmpty else { return }
        Task {
            await viewModel.imageService.prefetchThumbnails(items: items, size: thumbnailSize)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        // No-op: NSCache eviction handles cleanup
    }
}

// MARK: - Double Click

extension GridViewController {
    override func viewDidLayout() {
        super.viewDidLayout()
        let has = collectionView.gestureRecognizers.contains { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2 }
        guard !has else { return }
        let g = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        g.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(g)
    }

    @objc private func doubleClicked(_ g: NSClickGestureRecognizer) {
        let pt = g.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: pt) else { return }
        onOpenDetail?(ip.item)
    }
}
