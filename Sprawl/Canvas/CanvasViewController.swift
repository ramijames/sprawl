import AppKit

/// Hosts the zoomable scroll view and shows the current project's canvas. Remembers each
/// project's viewport (zoom + scroll) so switching projects — or relaunching the app —
/// re-frames the canvas exactly where it was left.
final class CanvasViewController: NSViewController {
    private let model: AppModel
    private let scrollView = CanvasScrollView()
    /// The project whose canvas is currently in the scroll view (so we can flush its viewport
    /// before swapping to another, and before snapshotting on quit).
    private weak var displayedProject: Project?

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
        observeViewport()
    }

    func showCurrentProject() {
        // Flush the outgoing project's viewport before swapping surfaces.
        if let outgoing = displayedProject, outgoing !== model.currentProject {
            captureViewport(into: outgoing)
        }
        guard let project = model.currentProject else { return }
        project.canvas.frame = NSRect(origin: .zero, size: CanvasView.canvasSize)
        scrollView.documentView = project.canvas
        displayedProject = project
        if project.hasViewport {
            restoreViewport(from: project)
        } else {
            centerViewport()
        }
    }

    func focusItem(_ item: WorkItem) {
        guard let window = item.window else { return }
        if window.superview !== scrollView.documentView { showCurrentProject() }
        (scrollView.documentView as? CanvasView)?.bringToFront(window)
        window.scrollToVisible(window.bounds)
        item.terminal?.focus()
    }

    /// Write the live scroll/zoom of the on-screen project back into its model, so a snapshot
    /// taken right after reflects the current viewport.
    func captureCurrentViewport() {
        if let project = displayedProject { captureViewport(into: project) }
    }

    private func captureViewport(into project: Project) {
        project.magnification = scrollView.magnification
        project.scrollOrigin = scrollView.contentView.bounds.origin
        project.hasViewport = true
    }

    private func restoreViewport(from project: Project) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.magnification = project.magnification
            let clip = self.scrollView.contentView
            clip.scroll(to: project.scrollOrigin)
            self.scrollView.reflectScrolledClipView(clip)
        }
    }

    private func centerViewport() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let clip = self.scrollView.contentView
            let target = NSPoint(
                x: (CanvasView.canvasSize.width - clip.bounds.width) / 2,
                y: (CanvasView.canvasSize.height - clip.bounds.height) / 2)
            clip.scroll(to: target)
            self.scrollView.reflectScrolledClipView(clip)
        }
    }

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
