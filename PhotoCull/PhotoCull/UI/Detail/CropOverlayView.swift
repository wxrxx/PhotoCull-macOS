// PhotoCull – UI/Detail/CropOverlayView.swift
// Transparent crop overlay drawn on top of the image in DetailViewController.

import AppKit

enum DragHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, interior
}

final class CropOverlayView: NSView {

    // MARK: - API

    var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { needsDisplay = true }
    }

    var imageDisplayRect: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    var aspectPreset: AspectPreset = .free
    var onCropChanged: ((CGRect) -> Void)?

    func setAspect(_ preset: AspectPreset) {
        aspectPreset = preset
        if let ratio = preset.ratio {
            cropRect = appliedAspect(to: cropRect, ratio: ratio)
            needsDisplay = true
            onCropChanged?(cropRect)
        }
    }

    func resetToFull() {
        aspectPreset = .original
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        needsDisplay = true
        onCropChanged?(cropRect)
    }

    // MARK: - State

    private let handleSize: CGFloat = 12
    private let handleHitRadius: CGFloat = 14
    private var activeHandle: DragHandle?
    private var dragStartMouseView: CGPoint = .zero
    private var dragStartCropView: CGRect = .zero

    // MARK: - Init

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = false }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = false }

    // MARK: - Coordinates

    private func viewRect(from norm: CGRect) -> CGRect {
        guard !imageDisplayRect.isEmpty else { return .zero }
        return CGRect(
            x: imageDisplayRect.minX + norm.minX * imageDisplayRect.width,
            y: imageDisplayRect.minY + norm.minY * imageDisplayRect.height,
            width: norm.width * imageDisplayRect.width,
            height: norm.height * imageDisplayRect.height
        )
    }

    private func normalisedRect(from viewSpace: CGRect) -> CGRect {
        guard !imageDisplayRect.isEmpty else { return cropRect }
        return CGRect(
            x: (viewSpace.minX - imageDisplayRect.minX) / imageDisplayRect.width,
            y: (viewSpace.minY - imageDisplayRect.minY) / imageDisplayRect.height,
            width: viewSpace.width / imageDisplayRect.width,
            height: viewSpace.height / imageDisplayRect.height
        )
    }

    private func handleCentres(for rect: CGRect) -> [DragHandle: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .top: CGPoint(x: rect.midX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
            .bottom: CGPoint(x: rect.midX, y: rect.minY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            .left: CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    // MARK: - Hit testing & Mouse

    func detectHit(at pt: CGPoint) -> DragHandle? {
        let viewR = viewRect(from: cropRect)
        for (h, c) in handleCentres(for: viewR) {
            let hr = CGRect(x: c.x - handleHitRadius/2, y: c.y - handleHitRadius/2, width: handleHitRadius, height: handleHitRadius)
            if hr.contains(pt) { return h }
        }
        return viewR.contains(pt) ? .interior : nil
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let hit = detectHit(at: pt) else { super.mouseDown(with: event); return }
        activeHandle = hit
        dragStartMouseView = pt
        dragStartCropView = viewRect(from: cropRect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = activeHandle else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - dragStartMouseView.x, dy = pt.y - dragStartMouseView.y

        var r = updatedRect(handle: handle, startRect: dragStartCropView, dx: dx, dy: dy)
        r = clamp(r, within: imageDisplayRect)
        if let ratio = aspectPreset.ratio { r = enforceAspect(ratio: ratio, rect: r, anchor: handle) }

        cropRect = normalisedRect(from: r)
        onCropChanged?(cropRect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { activeHandle = nil }

    // MARK: - Geometry math

    private func updatedRect(handle: DragHandle, startRect r: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minDim: CGFloat = 20
        switch handle {
        case .interior: return r.offsetBy(dx: dx, dy: dy)
        case .topLeft: return CGRect(x: r.minX + dx, y: r.minY, width: max(minDim, r.width - dx), height: max(minDim, r.height + dy))
        case .top: return CGRect(x: r.minX, y: r.minY, width: r.width, height: max(minDim, r.height + dy))
        case .topRight: return CGRect(x: r.minX, y: r.minY, width: max(minDim, r.width + dx), height: max(minDim, r.height + dy))
        case .right: return CGRect(x: r.minX, y: r.minY, width: max(minDim, r.width + dx), height: r.height)
        case .bottomRight: return CGRect(x: r.minX, y: r.minY + dy, width: max(minDim, r.width + dx), height: max(minDim, r.height - dy))
        case .bottom: return CGRect(x: r.minX, y: r.minY + dy, width: r.width, height: max(minDim, r.height - dy))
        case .bottomLeft: return CGRect(x: r.minX + dx, y: r.minY + dy, width: max(minDim, r.width - dx), height: max(minDim, r.height - dy))
        case .left: return CGRect(x: r.minX + dx, y: r.minY, width: max(minDim, r.width - dx), height: r.height)
        }
    }

    private func clamp(_ r: CGRect, within bounds: CGRect) -> CGRect {
        var ret = CGRect(x: r.origin.x, y: r.origin.y, width: min(r.width, bounds.width), height: min(r.height, bounds.height))
        ret.origin.x = max(bounds.minX, min(ret.origin.x, bounds.maxX - ret.width))
        ret.origin.y = max(bounds.minY, min(ret.origin.y, bounds.maxY - ret.height))
        return ret
    }

    private func enforceAspect(ratio: CGFloat, rect: CGRect, anchor: DragHandle) -> CGRect {
        guard anchor != .interior else { return rect }
        return CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.width / ratio)
    }

    private func appliedAspect(to norm: CGRect, ratio: CGFloat) -> CGRect {
        let newH = norm.width / ratio
        return CGRect(x: norm.origin.x, y: norm.origin.y, width: norm.width, height: min(newH, 1))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cropViewRect = viewRect(from: cropRect)

        // Vignette
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds); path.addRect(cropViewRect)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // Border
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(cropViewRect)

        // Thirds
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        let thW = cropViewRect.width / 3, thH = cropViewRect.height / 3
        for i in 1...2 {
            ctx.move(to: CGPoint(x: cropViewRect.minX + CGFloat(i)*thW, y: cropViewRect.minY))
            ctx.addLine(to: CGPoint(x: cropViewRect.minX + CGFloat(i)*thW, y: cropViewRect.maxY))
            ctx.move(to: CGPoint(x: cropViewRect.minX, y: cropViewRect.minY + CGFloat(i)*thH))
            ctx.addLine(to: CGPoint(x: cropViewRect.maxX, y: cropViewRect.minY + CGFloat(i)*thH))
        }
        ctx.strokePath()

        // Handles
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        for (_, c) in handleCentres(for: cropViewRect) {
            let hr = CGRect(x: c.x - handleSize/2, y: c.y - handleSize/2, width: handleSize, height: handleSize)
            ctx.fill(hr); ctx.stroke(hr)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ pt: NSPoint) -> NSView? { detectHit(at: pt) != nil ? self : nil }
}
