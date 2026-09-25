// ThumbnailCell.swift
// PhotoCull
//
// NSCollectionViewItem subclass for displaying photo thumbnails in the grid.
// All layout is programmatic — no XIB/NIB is used.

import AppKit

// MARK: - ThumbnailCell

final class ThumbnailCell: NSCollectionViewItem {

    // MARK: - Subviews

    /// Dark background container
    private let backgroundBox = NSBox()

    /// Displays the thumbnail image
    private let thumbnailImageView = NSImageView()

    /// Blue selection border overlay (layer-backed view)
    private let selectionBorderView = NSView()

    /// Small label in top-left: 'P' (picked) or 'X' (rejected)
    private let flagBadgeLabel = NSTextField(labelWithString: "")

    /// Colored square in top-right corner representing the color label
    private let colorSwatchView = NSView()

    /// Filename shown at the very bottom of the cell
    private let filenameLabel = NSTextField(labelWithString: "")

    /// Five circle views representing 1–5 star rating
    private var ratingCircles: [NSView] = []

    // MARK: - State

    /// The photo item currently bound to this cell
    private(set) var photoItem: PhotoItem?

    /// In-flight async thumbnail load task — cancelled on reuse
    private var loadTask: Task<Void, Never>?

    // MARK: - Layout constants

    private enum Layout {
        static let flagBadgeSize: CGFloat  = 18
        static let flagBadgePadding: CGFloat = 4
        static let colorSwatchSize: CGFloat = 10
        static let colorSwatchPadding: CGFloat = 4
        static let ratingCircleDiameter: CGFloat = 8
        static let ratingCircleSpacing: CGFloat = 4
        static let ratingRowHeight: CGFloat = 14
        static let ratingRowBottomPad: CGFloat = 20   // above filename
        static let filenameLabelHeight: CGFloat = 16
        static let selectionBorderWidth: CGFloat = 2.5
        static let cornerRadius: CGFloat = 4
    }

    // MARK: - loadView (programmatic, no XIB)

    override func loadView() {
        // Root view — NSCollectionViewItem.view must be set here
        let root = NSView()
        root.wantsLayer = true
        self.view = root

        setupBackgroundBox(in: root)
        setupThumbnailImageView()
        setupSelectionBorderView()
        setupFlagBadge()
        setupColorSwatch()
        setupFilenameLabel()
        setupRatingCircles()
        activateConstraints()
    }

    // MARK: - Subview Setup

    private func setupBackgroundBox(in root: NSView) {
        backgroundBox.boxType = .custom
        backgroundBox.fillColor = NSColor(white: 0.12, alpha: 1.0)
        backgroundBox.borderColor = NSColor(white: 0.25, alpha: 1.0)
        backgroundBox.borderWidth = 0.5
        backgroundBox.cornerRadius = Layout.cornerRadius
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backgroundBox)
    }

    private func setupThumbnailImageView() {
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = Layout.cornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(thumbnailImageView)
    }

    private func setupSelectionBorderView() {
        selectionBorderView.wantsLayer = true
        selectionBorderView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorderView.layer?.borderWidth = Layout.selectionBorderWidth
        selectionBorderView.layer?.cornerRadius = Layout.cornerRadius
        selectionBorderView.layer?.masksToBounds = true
        selectionBorderView.isHidden = true
        selectionBorderView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(selectionBorderView)
    }

    private func setupFlagBadge() {
        flagBadgeLabel.font = NSFont.boldSystemFont(ofSize: 10)
        flagBadgeLabel.alignment = .center
        flagBadgeLabel.wantsLayer = true
        flagBadgeLabel.layer?.cornerRadius = 3
        flagBadgeLabel.layer?.masksToBounds = true
        flagBadgeLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        flagBadgeLabel.isHidden = true
        flagBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(flagBadgeLabel)
    }

    private func setupColorSwatch() {
        colorSwatchView.wantsLayer = true
        colorSwatchView.layer?.cornerRadius = 2
        colorSwatchView.layer?.masksToBounds = true
        colorSwatchView.isHidden = true
        colorSwatchView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(colorSwatchView)
    }

    private func setupFilenameLabel() {
        filenameLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        filenameLabel.textColor = NSColor.secondaryLabelColor
        filenameLabel.alignment = .center
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(filenameLabel)
    }

    private func setupRatingCircles() {
        ratingCircles = (0..<5).map { _ in
            let circle = NSView()
            circle.wantsLayer = true
            circle.layer?.cornerRadius = Layout.ratingCircleDiameter / 2
            circle.layer?.masksToBounds = true
            circle.layer?.borderWidth = 1
            circle.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
            circle.layer?.backgroundColor = NSColor.clear.cgColor
            circle.translatesAutoresizingMaskIntoConstraints = false
            backgroundBox.addSubview(circle)
            return circle
        }
    }

    // MARK: - Auto Layout

    private func activateConstraints() {
        let d = Layout.self
        var constraints: [NSLayoutConstraint] = []

        // backgroundBox fills root
        constraints += [
            backgroundBox.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundBox.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundBox.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundBox.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]

        // filename label — pinned to bottom inside box
        constraints += [
            filenameLabel.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor, constant: 4),
            filenameLabel.trailingAnchor.constraint(equalTo: backgroundBox.trailingAnchor, constant: -4),
            filenameLabel.bottomAnchor.constraint(equalTo: backgroundBox.bottomAnchor, constant: -2),
            filenameLabel.heightAnchor.constraint(equalToConstant: d.filenameLabelHeight)
        ]

        // rating circles row — above filename
        let totalRatingWidth = CGFloat(5) * d.ratingCircleDiameter + CGFloat(4) * d.ratingCircleSpacing
        let ratingRowContainer = NSView()
        ratingRowContainer.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.addSubview(ratingRowContainer)

        constraints += [
            ratingRowContainer.centerXAnchor.constraint(equalTo: backgroundBox.centerXAnchor),
            ratingRowContainer.widthAnchor.constraint(equalToConstant: totalRatingWidth),
            ratingRowContainer.heightAnchor.constraint(equalToConstant: d.ratingCircleDiameter),
            ratingRowContainer.bottomAnchor.constraint(equalTo: filenameLabel.topAnchor, constant: -2)
        ]

        for (index, circle) in ratingCircles.enumerated() {
            let xOffset = CGFloat(index) * (d.ratingCircleDiameter + d.ratingCircleSpacing)
            constraints += [
                circle.leadingAnchor.constraint(equalTo: ratingRowContainer.leadingAnchor, constant: xOffset),
                circle.centerYAnchor.constraint(equalTo: ratingRowContainer.centerYAnchor),
                circle.widthAnchor.constraint(equalToConstant: d.ratingCircleDiameter),
                circle.heightAnchor.constraint(equalToConstant: d.ratingCircleDiameter)
            ]
        }

        // thumbnailImageView — fills from top to just above rating row
        constraints += [
            thumbnailImageView.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: backgroundBox.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: backgroundBox.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: ratingRowContainer.topAnchor, constant: -2)
        ]

        // selection border overlay — same frame as backgroundBox interior
        constraints += [
            selectionBorderView.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor),
            selectionBorderView.trailingAnchor.constraint(equalTo: backgroundBox.trailingAnchor),
            selectionBorderView.topAnchor.constraint(equalTo: backgroundBox.topAnchor),
            selectionBorderView.bottomAnchor.constraint(equalTo: backgroundBox.bottomAnchor)
        ]

        // flag badge — top-left of image area
        constraints += [
            flagBadgeLabel.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor, constant: d.flagBadgePadding),
            flagBadgeLabel.topAnchor.constraint(equalTo: backgroundBox.topAnchor, constant: d.flagBadgePadding),
            flagBadgeLabel.widthAnchor.constraint(equalToConstant: d.flagBadgeSize),
            flagBadgeLabel.heightAnchor.constraint(equalToConstant: d.flagBadgeSize)
        ]

        // color swatch — top-right of image area
        constraints += [
            colorSwatchView.trailingAnchor.constraint(equalTo: backgroundBox.trailingAnchor, constant: -d.colorSwatchPadding),
            colorSwatchView.topAnchor.constraint(equalTo: backgroundBox.topAnchor, constant: d.colorSwatchPadding),
            colorSwatchView.widthAnchor.constraint(equalToConstant: d.colorSwatchSize),
            colorSwatchView.heightAnchor.constraint(equalToConstant: d.colorSwatchSize)
        ]

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Public Configure

    /// Binds a `PhotoItem` to the cell, cancels any previous async load, and
    /// launches a new Task to fetch the thumbnail via `ImageLoadingService`.
    func configure(
        with item: PhotoItem,
        thumbnailSize: CGFloat,
        imageService: ImageLoadingService
    ) {
        photoItem = item

        // Cancel any stale in-flight load
        loadTask?.cancel()
        loadTask = nil

        // Clear stale image immediately so recycled cells don't flash old content
        thumbnailImageView.image = nil

        // Filename
        filenameLabel.stringValue = item.filename

        // Update badge / swatch / rating synchronously (cheap)
        updateFlagBadge(flag: item.flag)
        updateColorSwatch(label: item.label)
        updateRatingCircles(rating: item.rating)

        // Async thumbnail fetch
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await imageService.loadThumbnail(for: item, size: thumbnailSize)
            // Only apply if not cancelled and item still matches
            guard !Task.isCancelled, self.photoItem?.sourceURL == item.sourceURL else { return }
            await MainActor.run {
                self.thumbnailImageView.image = image
            }
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        thumbnailImageView.image = nil
        photoItem = nil
        flagBadgeLabel.isHidden = true
        colorSwatchView.isHidden = true
        filenameLabel.stringValue = ""
        resetRatingCircles()
    }

    // MARK: - Selection Override

    override var isSelected: Bool {
        didSet {
            selectionBorderView.isHidden = !isSelected
            // Slightly brighten background when selected
            backgroundBox.fillColor = isSelected
                ? NSColor(white: 0.20, alpha: 1.0)
                : NSColor(white: 0.12, alpha: 1.0)
        }
    }

    // MARK: - Private Helpers

    private func updateFlagBadge(flag: FlagStatus) {
        switch flag {
        case .picked:
            flagBadgeLabel.stringValue = "P"
            flagBadgeLabel.textColor = .systemGreen
            flagBadgeLabel.isHidden = false
        case .rejected:
            flagBadgeLabel.stringValue = "X"
            flagBadgeLabel.textColor = .systemRed
            flagBadgeLabel.isHidden = false
        case .unflagged:
            flagBadgeLabel.isHidden = true
        }
    }

    private func updateColorSwatch(label: ColorLabel) {
        let color: NSColor
        switch label {
        case .none:
            colorSwatchView.isHidden = true
            return
        case .red:
            color = .systemRed
        case .yellow:
            color = .systemYellow
        case .green:
            color = .systemGreen
        case .blue:
            color = .systemBlue
        case .purple:
            color = .systemPurple
        }
        colorSwatchView.layer?.backgroundColor = color.cgColor
        colorSwatchView.isHidden = false
    }

    private func updateRatingCircles(rating: StarRating) {
        let filled = rating.rawValue   // 0 – 5
        for (index, circle) in ratingCircles.enumerated() {
            if index < filled {
                // Filled star
                circle.layer?.backgroundColor = NSColor.systemYellow.cgColor
                circle.layer?.borderColor = NSColor.systemYellow.cgColor
            } else {
                // Empty circle
                circle.layer?.backgroundColor = NSColor.clear.cgColor
                circle.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
            }
        }
    }

    private func resetRatingCircles() {
        for circle in ratingCircles {
            circle.layer?.backgroundColor = NSColor.clear.cgColor
            circle.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        }
    }
}
