//
//  RenderLoopCaretTests.swift
//  SwiftTermTests
//
//  Frames drawn on the render loop cannot move the caret view, which
//  `caretFrame` and the marked-text overlay are placed from. The loop sends
//  the cursor's placement back to main with the frame's side effects.
//

#if os(macOS) || os(iOS)
import Testing
@testable import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite(.serialized)
struct RenderLoopCaretTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

#if os(macOS)
    /// A window that is never ordered in, so nothing reaches the screen; the
    /// occlusion pause is off for it.
    private func makeWindowedView() -> (NSWindow, TerminalView) {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: frame)
        window.contentView = view
        view.suspendsRenderingWhenNotVisible = false
        return (window, view)
    }

    private func close(_ view: TerminalView, _ window: NSWindow) {
        _ = view.updateUiClosed()
        window.close()
    }
#else
    private func makeWindowedView() -> (UIWindow, TerminalView) {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let window = UIWindow(frame: frame)
        window.isHidden = false
        let view = TerminalView(frame: frame)
        window.addSubview(view)
        view.layoutIfNeeded()
        return (window, view)
    }

    private func close(_ view: TerminalView, _ window: UIWindow) {
        _ = view.updateUiClosed()
        view.removeFromSuperview()
        window.isHidden = true
    }
#endif

    @Test(.enabled(if: RenderLoopCaretTests.metalIsUsable))
    func caretFrameFollowsTheCursorOnTheRenderLoop() async throws {
        let (window, view) = makeWindowedView()
        defer { close(view, window) }
        try view.setUseMetal(true)
        #expect(view.isUsingRenderLoop)
        let cellWidth = view.cellDimension.width

        view.feed(text: "abcde")
        view.frameTick()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, abs(view.caretFrame.minX - cellWidth * 5) > 0.5 {
            // A test window gets no display ticks: stand in for them.
            view.frameDriver.renderClock?.sourceDidTick()
            await drainMainQueue()
        }
        #expect(abs(view.caretFrame.minX - cellWidth * 5) <= 0.5)

        view.feed(text: "\r\nxy")
        view.frameTick()
        let next = Date().addingTimeInterval(2)
        while Date() < next, abs(view.caretFrame.minX - cellWidth * 2) > 0.5 {
            // A test window gets no display ticks: stand in for them.
            view.frameDriver.renderClock?.sourceDidTick()
            await drainMainQueue()
        }
        #expect(abs(view.caretFrame.minX - cellWidth * 2) <= 0.5)
    }
}
#endif
