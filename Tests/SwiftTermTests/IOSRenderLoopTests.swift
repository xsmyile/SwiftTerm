//
//  IOSRenderLoopTests.swift
//  SwiftTermTests
//
//  The iOS terminal view draws Metal frames into a CAMetalLayer it owns, on
//  the render loop, as macOS does (io-gaps.md G1, WO-F4). These pin what runs
//  where, the pause while nothing can see the view, and moving between
//  windows.
//

#if os(iOS) || os(visionOS)
import MetalKit
import UIKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct IOSRenderLoopTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    private let frame = CGRect(x: 0, y: 0, width: 390, height: 300)

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: frame)
        window.isHidden = false
        return window
    }

    private func makeWindowedView() -> (UIWindow, TerminalView) {
        let window = makeWindow()
        let view = TerminalView(frame: frame)
        window.addSubview(view)
        view.layoutIfNeeded()
        return (window, view)
    }

    private func close(_ view: TerminalView, _ window: UIWindow) {
        #expect(view.updateUiClosed())
        view.removeFromSuperview()
        window.isHidden = true
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Keeps the main thread busy, without turning its run loop, until
    /// `condition` holds or `timeout` passes. Anything that happens meanwhile
    /// happened on another thread.
    private func spinMainThread(timeout: TimeInterval = 2,
                                until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
        }
        return condition()
    }

    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func layerSurfaceIsTheDefaultAndRunsTheLoop() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }

        try view.setUseMetal(true)

        #expect(view.usesMetalLayerSurface)
        #expect(view.metalView is TerminalMetalLayerView)
        #expect(view.isUsingRenderLoop)
        #expect(view.frameDriver.renderClock != nil)
    }

    /// The frame tick on main only captures the view state and signals the
    /// loop: the frame is prepared and submitted while main is still busy.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func framesAreDrawnWhileTheMainThreadIsBusy() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)
        view.feed(text: "drawn off the main thread\r\n")
        view.renderOwner.resetMetalCounters()

        view.frameTick()

        #expect(spinMainThread { view.renderOwner.completedMetalRenders > 0 })
    }

    /// The `MTKView` surface stays selectable, and it draws only when the main
    /// run loop turns: the same busy main thread gets no frame.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func mtkViewSurfaceDrawsOnlyFromTheMainRunLoop() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUsesMetalLayerSurface(false)
        try view.setUseMetal(true)
        #expect(view.metalView is MTKView)
        #expect(!view.isUsingRenderLoop)
        view.feed(text: "drawn by the view system\r\n")
        view.renderOwner.resetMetalCounters()

        view.frameTick()

        #expect(!spinMainThread(timeout: 0.3) { view.renderOwner.completedMetalRenders > 0 })
    }

    /// Switching the surface while Metal runs rebuilds it in place and starts
    /// or stops the loop with it.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func switchingTheSurfaceRebuildsItInPlace() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)

        try view.setUsesMetalLayerSurface(false)
        #expect(view.isUsingMetalRenderer)
        #expect(view.metalView is MTKView)
        #expect(!view.isUsingRenderLoop)

        try view.setUsesMetalLayerSurface(true)
        #expect(view.metalView is TerminalMetalLayerView)
        #expect(view.isUsingRenderLoop)
        #expect(view.subviews.filter { $0 is MetalRenderTarget }.count == 1)
    }

    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func turningMetalOffStopsTheLoop() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }

        for _ in 0..<4 {
            try view.setUseMetal(true)
            #expect(view.isUsingRenderLoop)
            try view.setUseMetal(false)
            #expect(!view.isUsingMetalRenderer)
            #expect(!view.isUsingRenderLoop)
            #expect(view.metalView == nil)
        }
    }

    /// Leaving the window stops the loop; joining another starts it again,
    /// and frames reach the new window.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func movingToAnotherWindowRestartsTheLoop() throws {
        let (first, view) = makeWindowedView()
        let second = makeWindow()
        defer {
            close(view, second)
            first.isHidden = true
        }
        try view.setUseMetal(true)

        view.removeFromSuperview()
        #expect(!view.isUsingRenderLoop)

        second.addSubview(view)
        view.layoutIfNeeded()
        #expect(view.isUsingRenderLoop)
        view.feed(text: "in the second window\r\n")
        view.renderOwner.resetMetalCounters()
        view.frameTick()
        #expect(spinMainThread { view.renderOwner.completedMetalRenders > 0 })
    }

    /// In the background the frame driver stops ticking, and nothing else
    /// signals the loop: output arriving then draws nothing until the app
    /// comes back, and then one frame covers it.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func backgroundPausesFramesAndForegroundResumes() async throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)
        let center = NotificationCenter.default

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await drainMainQueue()
        #expect(view.frameDriver.isVisibilitySuspended)
        view.renderLoop?.resetCounters()

        for line in 0..<50 {
            view.feed(text: "while in the background \(line)\r\n")
        }
        await drainMainQueue()
        await drainMainQueue()
        #expect(view.renderLoop?.currentCounters.signals == 0)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drainMainQueue()
        #expect(!view.frameDriver.isVisibilitySuspended)
        #expect(spinMainThread { (view.renderLoop?.currentCounters.frames ?? 0) > 0 })
    }

    /// A resize reaches the screen with a drawable of the new size in the
    /// layout's Core Animation transaction. Drawn on the render loop instead,
    /// it is presented outside that transaction: the previous drawable is
    /// shown stretched to the new bounds, and a rotation waits for it.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func aResizeDrawsTheNewSizeDuringLayout() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)
        let surface = try #require(view.metalView as? TerminalMetalLayerView)
        view.layoutIfNeeded()
        let rendersBefore = view.renderOwner.completedMetalRenders

        view.frame.size = CGSize(width: 300, height: 390)
        view.layoutIfNeeded()

        #expect(view.renderOwner.completedMetalRenders == rendersBefore + 1)
        #expect(surface.bounds.size == view.bounds.size)
        #expect(surface.renderDrawableSize ==
                CGSize(width: 300 * surface.renderContentsScale, height: 390 * surface.renderContentsScale))
        #expect(surface.metalLayer.presentsWithTransaction == false)
    }

    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func aLayoutWithoutResizeLeavesTheFrameToTheLoop() throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)
        view.layoutIfNeeded()
        let rendersBefore = view.renderOwner.completedMetalRenders

        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(view.renderOwner.completedMetalRenders == rendersBefore)
    }

    /// A rotation or the keyboard resizes the layer without changing its
    /// scale, and the drawable has to follow, at the scale the host draws at.
    @Test func layerDrawableFollowsResizeAtTheHostScale() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let surface = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        surface.hostContentsScale = 2
        window.addSubview(surface)
        surface.layoutIfNeeded()
        #expect(surface.metalLayer.contentsScale == 2)
        #expect(surface.renderDrawableSize == CGSize(width: 200, height: 100))
        #expect(surface.renderGeometry.drawableSize == CGSize(width: 200, height: 100))

        surface.frame = CGRect(x: 0, y: 0, width: 300, height: 80)
        surface.layoutIfNeeded()
        #expect(surface.renderDrawableSize == CGSize(width: 600, height: 160))
        #expect(surface.renderGeometry.bounds.size == CGSize(width: 300, height: 80))
    }

    /// Same renderer, same snapshot: the two surfaces must produce the same
    /// pixels, and something other than the background.
    @Test(.enabled(if: IOSRenderLoopTests.metalIsUsable))
    func layerAndMTKViewSurfacesDrawTheSamePixels() {
        let result = TerminalView.compareMetalSurfaces()
        #expect(result.unavailableReason == nil)
        #expect(result.nonUniformPixels > 0)
        #expect(result.differingPixels == 0)
    }
}
#endif
