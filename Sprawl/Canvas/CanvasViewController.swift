import AppKit

/// Hosts the zoomable scroll view over the single shared canvas. The viewport (zoom + scroll) is
/// now global; it's captured into / restored from the model rather than per project.
final class CanvasViewController: NSViewController {
    private let model: AppModel
    private let scrollView = CanvasScrollView()

    /// The canvas was panned or zoomed — request an autosave of the viewport.
    var onViewportChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        model.canvas.frame = NSRect(origin: .zero, size: CanvasView.canvasSize)
        scrollView.documentView = model.canvas
        observeViewport()
    }

    /// Apply the saved global viewport on launch, or center on the canvas if none.
    func restoreGlobalViewport() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let clip = self.scrollView.contentView
            if let v = self.model.viewport {
                self.scrollView.magnification = v.magnification
                clip.scroll(to: v.scrollOrigin)
            } else {
                clip.scroll(to: NSPoint(
                    x: (CanvasView.canvasSize.width - clip.bounds.width) / 2,
                    y: (CanvasView.canvasSize.height - clip.bounds.height) / 2))
            }
            self.scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Flush the live viewport into the model so the next snapshot is current.
    func captureCurrentViewport() {
        model.viewport = ViewportState(magnification: scrollView.magnification,
                                       scrollOrigin: scrollView.contentView.bounds.origin)
    }

    func focusItem(_ item: WorkItem) {
        guard let window = item.window else { return }
        model.canvas.bringToFront(window)
        window.scrollToVisible(window.bounds)
        item.terminal?.focus()
    }

    /// Pan/zoom so the project's folder is framed in the viewport.
    func focusProject(_ project: Project) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let padded = self.model.canvas.folderBounds(for: project).insetBy(dx: -80, dy: -80)
            let onScreen = self.scrollView.contentView.frame.size   // unscaled clip size
            guard padded.width > 0, padded.height > 0, onScreen.width > 0 else { return }
            let fit = min(onScreen.width / padded.width, onScreen.height / padded.height)
            let mag = max(self.scrollView.minMagnification, min(self.scrollView.maxMagnification, fit))
            self.scrollView.magnification = mag
            let clip = self.scrollView.contentView   // bounds now reflect the new magnification
            clip.scroll(to: NSPoint(x: padded.midX - clip.bounds.width / 2,
                                    y: padded.midY - clip.bounds.height / 2))
            self.scrollView.reflectScrolledClipView(clip)
            self.onViewportChange?()
        }
    }

    func freeAnchorNearViewport() -> NSPoint { model.canvas.freeAnchorNearViewport() }

    // MARK: - Viewport change observation (drives autosave)

    private func observeViewport() {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewportChanged),
                           name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(viewportChanged),
                           name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    @objc private func viewportChanged() { onViewportChange?() }

    // MARK: - Zoom (forwarded from menu via MainSplitViewController)

    func zoomIn() { scrollView.zoomIn(); onViewportChange?() }
    func zoomOut() { scrollView.zoomOut(); onViewportChange?() }
    func zoomReset() { scrollView.zoomReset(); onViewportChange?() }
}
