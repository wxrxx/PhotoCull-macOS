// PhotoCull – UI/Detail/FilmstripView.swift
// Horizontal filmstrip for DetailViewController.

import AppKit
import Combine

// MARK: - FilmstripCell

final class FilmstripCell: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FilmstripCell")

    private let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let selectionOverlay: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemYellow.cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 2
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 90))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(imageView)
        view.addSubview(selectionOverlay)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            selectionOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func configure(with item: PhotoItem, imageService: ImageLoadingService, isSelected: Bool) {
        imageView.image = nil
        selectionOverlay.isHidden = !isSelected
        Task { [weak self] in
            let thumbnail = await imageService.loadThumbnail(for: item, size: 90)
            await MainActor.run { self?.imageView.image = thumbnail }
        }
    }

    override var isSelected: Bool {
        didSet { selectionOverlay.isHidden = !isSelected }
    }
}

// MARK: - FilmstripViewController

final class FilmstripViewController: NSViewController {

    var currentIndex: Int = 0 {
        didSet {
            guard currentIndex != oldValue else { return }
            reloadSelection(from: oldValue, to: currentIndex)
            scrollToCurrentIndex()
        }
    }

    var onSelectIndex: ((Int) -> Void)?

    private let viewModel: PhotoLibraryViewModel
    private var cancellables = Set<AnyCancellable>()

    private lazy var scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var collectionView: NSCollectionView = {
        let cv = NSCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 90, height: 90)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.backgroundColors = [.clear]
        cv.dataSource = self
        cv.delegate = self
        cv.register(FilmstripCell.self, forItemWithIdentifier: FilmstripCell.reuseIdentifier)
        return cv
    }()

    init(viewModel: PhotoLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.documentView = collectionView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        viewModel.$filteredPhotos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.collectionView.reloadData()
                self.applySelection(at: self.currentIndex)
                self.scrollToCurrentIndex()
            }
            .store(in: &cancellables)
    }

    private func reloadSelection(from oldIndex: Int, to newIndex: Int) {
        let safeItems = [oldIndex, newIndex]
            .filter { $0 < viewModel.filteredPhotos.count && $0 >= 0 }
            .map { IndexPath(item: $0, section: 0) }
        collectionView.reloadItems(at: Set(safeItems))
        applySelection(at: newIndex)
    }

    private func applySelection(at index: Int) {
        guard index >= 0, index < viewModel.filteredPhotos.count else { return }
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }

    private func scrollToCurrentIndex() {
        guard currentIndex >= 0, currentIndex < viewModel.filteredPhotos.count else { return }
        collectionView.scrollToItems(at: [IndexPath(item: currentIndex, section: 0)], scrollPosition: .centeredHorizontally)
    }
}

extension FilmstripViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.filteredPhotos.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FilmstripCell.reuseIdentifier, for: indexPath) as! FilmstripCell
        let item = viewModel.filteredPhotos[indexPath.item]
        cell.configure(with: item, imageService: viewModel.imageService, isSelected: indexPath.item == currentIndex)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first else { return }
        onSelectIndex?(ip.item)
    }
}
