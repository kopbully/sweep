import AppKit
import SwiftUI
import WebKit

/// Desktop widget geometry. The hole is deliberately small: it floats over the
/// desktop, so every extra point of its 240pt predecessor stole clicks from
/// whatever sat underneath it.
enum BlackHoleMetrics {
    static let side: CGFloat = 168
    static let dropRadius: CGFloat = 62
    /// Pointer response starts before the ring is reached, so the hole can grow
    /// as the cursor approaches without waiting for a hit.
    static let hoverInner: CGFloat = 18
    static let hoverOuter: CGFloat = 84
    /// Outside this radius the window stops accepting mouse events entirely and
    /// clicks fall through to the desktop.
    static let passThroughRadius: CGFloat = dropRadius + 12
    static let cornerInset: CGFloat = 22
    static let bottomInset: CGFloat = 84
    static var center: NSPoint { NSPoint(x: side / 2, y: side / 2) }

    static func strength(distance: CGFloat) -> CGFloat {
        let span = hoverOuter - hoverInner
        return max(0, min(1, 1 - (distance - hoverInner) / span))
    }
}

@MainActor
final class BlackHoleController: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = BlackHoleController()
    private static let preferenceKey = "SweepDesktopBlackHoleEnabled"
    @Published private(set) var isVisible = false
    @Published private(set) var lastMessage = "拖入文件移到废纸篓，可从废纸篓恢复"

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var bridge: BlackHoleBridge?
    private var rendererPage: URL?
    private var rendererFailureMessage: String?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var proximityTimer: Timer?
    private var ready = false
    private var busy = false
    private var dragging = false
    private var near = false
    private var lastPointerUpdate = 0.0

    func restoreIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.preferenceKey) { show() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil { createPanel() }
        else if !ready { reloadRenderer() }
        guard let panel else { return }
        isVisible = true
        UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        call("setActive", argument: true)
        installPointerMonitors()
        updatePointer(force: true)
    }

    @objc func hide() {
        call("setActive", argument: false)
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = false
        isVisible = false
        near = false
        UserDefaults.standard.set(false, forKey: Self.preferenceKey)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        proximityTimer?.invalidate()
        proximityTimer = nil
    }

    func shutdown() {
        let enabled = isVisible
        hide()
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sweepHole")
    }

    private func createPanel() {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("BlackHole/index.html")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/BlackHole/index.html")
        guard let page = [packaged, development].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            lastMessage = "黑洞资源缺失，请重新打包 Sweep"
            return
        }
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let side = BlackHoleMetrics.side
        let frame = NSRect(x: visible.maxX - side - BlackHoleMetrics.cornerInset,
                           y: visible.minY + BlackHoleMetrics.bottomInset,
                           width: side, height: side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Sweep 桌面黑洞"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let configuration = WKWebViewConfiguration()
        let bridge = BlackHoleBridge(controller: self)
        configuration.userContentController.add(bridge, name: "sweepHole")
        let webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        let contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.addSubview(webView)
        let dropView = BlackHoleDropView(frame: contentView.bounds)
        dropView.controller = self
        dropView.autoresizingMask = [.width, .height]
        // Keep WebKit's own drag destinations below the native file receiver.
        contentView.addSubview(dropView, positioned: .above, relativeTo: webView)
        panel.contentView = contentView
        self.panel = panel
        self.webView = webView
        self.bridge = bridge
        self.rendererPage = page
        OperationsLog.write("BLACKHOLE PANEL frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) side=\(Int(side)) visible=\(Int(visible.origin.y))+\(Int(visible.height))")
        reloadRenderer()
    }

    private func reloadRenderer() {
        guard let rendererPage, let webView else { return }
        ready = false
        webView.loadFileURL(rendererPage, allowingReadAccessTo: rendererPage.deletingLastPathComponent())
    }

    private func rendererUnavailable(_ reason: String) {
        ready = false
        lastMessage = "黑洞画面已暂停：\(reason)。隐藏后再次打开可重试"
        rendererFailureMessage = lastMessage
        OperationsLog.write("BLACKHOLE RENDER_ERROR")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rendererUnavailable("画面进程已结束")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { rendererUnavailable(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { rendererUnavailable(error.localizedDescription) }
    }

    private func installPointerMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updatePointer()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.updatePointer()
        }
        // While the window is click-through it receives no local events, so a
        // cheap 12 Hz poll decides when the cursor is back inside the ring.
        guard proximityTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointer(force: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func updatePointer(force: Bool = false) {
        guard isVisible, let panel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPointerUpdate >= 1.0 / 30 else { return }
        lastPointerUpdate = now
        let cursor = NSEvent.mouseLocation
        let point = NSPoint(x: cursor.x - panel.frame.minX, y: panel.frame.maxY - cursor.y)
        let center = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        updateHitRegion(distance: hypot(point.x - center.x, point.y - center.y), panel: panel)
        sendPointer(point, dragging: dragging)
    }

    /// Corners of the panel are empty pixels: let them reach the desktop instead
    /// of swallowing the click. Native drag/drop and drag-to-move stay available
    /// because both happen inside the ring.
    private func updateHitRegion(distance: CGFloat, panel: NSPanel) {
        let ignoring = !dragging && distance > BlackHoleMetrics.passThroughRadius
        if panel.ignoresMouseEvents != ignoring {
            panel.ignoresMouseEvents = ignoring
            OperationsLog.write("BLACKHOLE HIT_REGION passThrough=\(ignoring) distance=\(Int(distance))")
        }
    }

    private func sendPointer(_ point: NSPoint, dragging: Bool) {
        guard let panel else { return }
        let center = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        let distance = hypot(point.x - center.x, point.y - center.y)
        let strength = BlackHoleMetrics.strength(distance: distance)
        let isNear = strength > 0
        let wasNear = near
        if near != isNear {
            near = isNear
            OperationsLog.write(isNear ? "BLACKHOLE POINTER_ENTER" : "BLACKHOLE POINTER_LEAVE")
        }
        // No IPC while the cursor remains far away; AppKit coordinates are logical points on every display.
        if !isNear && !dragging {
            if wasNear { call("setPointer", argument: ["x": center.x, "y": center.y, "strength": 0, "dragging": false]) }
            return
        }
        call("setPointer", argument: ["x": point.x, "y": point.y, "strength": strength, "dragging": dragging])
    }

    func dragHover(at point: NSPoint, active: Bool) {
        dragging = active
        // A drag already in flight must be able to land even if it entered from
        // a corner that was click-through a moment ago.
        if active { panel?.ignoresMouseEvents = false }
        sendPointer(point, dragging: active)
    }

    var canAcceptDrop: Bool { ready && !busy && isVisible }

    static func trashDragOperation(for source: NSDragOperation) -> NSDragOperation {
        // Sweep owns the asynchronous Trash operation. Do not ask the source to
        // remove its data on drag completion before the actual result is known.
        if source.contains(.generic) { return .generic }
        return []
    }

    func accept(_ urls: [URL], at point: NSPoint) -> Bool {
        guard canAcceptDrop else {
            lastMessage = busy ? "正在处理上一批文件，请稍候" : "黑洞正在加载，请稍候"
            return false
        }
        let targets = BlackHoleTrash.candidates(urls)
        guard !targets.isEmpty else { return false }
        busy = true
        dragging = false
        lastMessage = "正在将 \(targets.count) 项移到废纸篓…"
        let origin = ["x": point.x, "y": point.y]
        let batchID = UUID().uuidString
        let itemIDs = Dictionary(uniqueKeysWithValues: targets.enumerated().map {
            ($0.element.path, "\(batchID)-\($0.offset)")
        })
        let items: [[String: Any]] = targets.map { url in
            ["id": itemIDs[url.path]!, "name": url.lastPathComponent, "icon": iconDataURL(for: url)]
        }
        call("prepare", arguments: [items, origin])
        OperationsLog.write("BLACKHOLE DROP count=\(targets.count)")
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                BlackHoleTrash.moveToTrash(targets)
            }.value
            guard let self else { return }
            let ok = results.filter(\.ok).count
            let failed = results.count - ok
            self.lastMessage = failed == 0 ? "已将 \(ok) 项移到废纸篓" : "\(ok) 项已回收，\(failed) 项失败：\(results.first { !$0.ok }?.error ?? "请查看权限")"
            let payload: [[String: Any]] = results.map {
                ["id": itemIDs[$0.id]!, "ok": $0.ok, "error": $0.error ?? ""]
            }
            self.call("complete", arguments: [payload, origin])
            self.busy = false
            self.updatePointer(force: true)
        }
        return true
    }

    private func iconDataURL(for url: URL) -> String {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func call(_ method: String, argument: Any) { call(method, arguments: [argument]) }

    private func call(_ method: String, arguments: [Any]) {
        guard ready, let webView else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed])
            let json = String(decoding: data, as: UTF8.self)
            webView.evaluateJavaScript("window.sweepHole?.\(method)(...\(json))") { _, error in
                if let error { OperationsLog.write("BLACKHOLE RENDER_CALL_FAIL \(method): \(error.localizedDescription)") }
            }
        } catch {
            lastMessage = "黑洞消息编码失败：\(error.localizedDescription)"
        }
    }

    fileprivate func receive(_ message: Any) {
        guard let message = message as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if lastMessage == rendererFailureMessage {
                lastMessage = "拖入文件移到废纸篓，可从废纸篓恢复"
            }
            rendererFailureMessage = nil
            call("setActive", argument: isVisible)
            updatePointer(force: true)
            OperationsLog.write("BLACKHOLE READY")
        case "animation-complete":
            OperationsLog.write("BLACKHOLE ABSORB_COMPLETE count=\((message["ids"] as? [String])?.count ?? 0)")
        case "render-error":
            rendererUnavailable(message["message"] as? String ?? "请重新打开")
        default: break
        }
    }
}

@MainActor
private final class BlackHoleBridge: NSObject, WKScriptMessageHandler {
    weak var controller: BlackHoleController?
    init(controller: BlackHoleController) { self.controller = controller }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        controller?.receive(message.body)
    }
}

@MainActor
private final class BlackHoleDropView: NSView {
    weak var controller: BlackHoleController?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sweep 桌面黑洞")
        setAccessibilityHelp("鼠标靠近会响应；拖入文件移到废纸篓；左键拖动位置，右键隐藏")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // This topmost sibling owns mouse events and Finder drops; WebKit only renders.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "隐藏桌面黑洞", action: #selector(BlackHoleController.hide), keyEquivalent: "")
        hide.target = controller
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func point(_ sender: NSDraggingInfo) -> NSPoint {
        let local = convert(sender.draggingLocation, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func accepted(_ sender: NSDraggingInfo) -> Bool {
        let point = point(sender)
        return controller?.canAcceptDrop == true && !urls(sender).isEmpty
            && !BlackHoleController.trashDragOperation(for: sender.draggingSourceOperationMask).isEmpty
            && hypot(point.x - bounds.midX, point.y - bounds.midY) <= BlackHoleMetrics.dropRadius
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = point(sender)
        OperationsLog.write("BLACKHOLE DRAG_ENTER files=\(urls(sender).count) source=\(sender.draggingSourceOperationMask.rawValue) ready=\(controller?.canAcceptDrop == true) x=\(Int(point.x)) y=\(Int(point.y))")
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = accepted(sender)
        controller?.dragHover(at: point(sender), active: valid)
        return valid ? BlackHoleController.trashDragOperation(for: sender.draggingSourceOperationMask) : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragHover(at: BlackHoleMetrics.center, active: false)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let valid = accepted(sender)
        OperationsLog.write("BLACKHOLE DRAG_PREPARE accepted=\(valid)")
        return valid
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepted(sender) else { return false }
        return controller?.accept(urls(sender), at: point(sender)) ?? false
    }
}
