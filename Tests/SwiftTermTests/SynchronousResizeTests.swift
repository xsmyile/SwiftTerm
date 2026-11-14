//
//  SynchronousResizeTests.swift
//  SwiftTermTests
//
//  `resize(cols:rows:softReset:)` puts a grid in place before it returns,
//  also during a live resize, where `setFrameSize` only queues one, and keeps
//  the program's modes when asked to. `clipboardCopy(source:content:)` on the
//  view can be overridden to see an OSC 52 write where it is parsed.
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SynchronousResizeTests {

    private final class SizeRecordingDelegate: TerminalViewDelegate {
        var sizes: [(cols: Int, rows: Int)] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            sizes.append((cols: newCols, rows: newRows))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// Reports itself as mid-drag, as `ResizeCoalescingTests` does: AppKit
    /// sets `inLiveResize` only during a real drag.
    private final class LiveResizingTerminalView: TerminalView {
        override var inLiveResize: Bool { true }
    }

    /// Sees each OSC 52 write on the thread that parses it.
    private final class ClipboardWatchingTerminalView: TerminalView {
        private let lock = NSLock()
        private var writes: [Data] = []

        var copied: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return writes
        }

        nonisolated override func clipboardCopy(source: Terminal, content: Data) {
            lock.lock()
            writes.append(content)
            lock.unlock()
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeLiveView(delegate: TerminalViewDelegate) -> (TerminalView, ManualTickSource) {
        let view = LiveResizingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        view.frameDriver.invalidate()
        view.processSizeChange(newSize: view.frame.size)
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        driver.onTick = { [weak view] in view?.frameTick() }
        view.frameDriver = driver
        view.terminalDelegate = delegate
        return (view, source)
    }

    @Test func duringALiveResizeTheGridIsInPlaceAtOnce() async {
        let delegate = SizeRecordingDelegate()
        let (view, _) = makeLiveView(delegate: delegate)
        await drainMainQueue()
        delegate.sizes.removeAll()

        view.resize(cols: 50, rows: 10, softReset: false)

        let actual = view.withTerminal { ($0.cols, $0.rows) }
        #expect(actual.0 == 50)
        #expect(actual.1 == 10)
        #expect(delegate.sizes.count == 1)
        #expect(delegate.sizes.first?.cols == 50)
        #expect(delegate.sizes.first?.rows == 10)
    }

    /// A size a live drag queued before the explicit resize does not undo it
    /// when the next frame applies the queue.
    @Test func aSizeQueuedBeforeDoesNotUndoIt() async {
        let delegate = SizeRecordingDelegate()
        let (view, source) = makeLiveView(delegate: delegate)
        await drainMainQueue()

        view.setFrameSize(CGSize(width: 900, height: 700))
        view.resize(cols: 50, rows: 10, softReset: false)
        await drainMainQueue()
        source.tick()
        await drainMainQueue()

        let actual = view.withTerminal { ($0.cols, $0.rows) }
        #expect(actual.0 == 50)
        #expect(actual.1 == 10)
    }

    @Test func withoutASoftResetTheProgramsModesStay() {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        view.frameDriver.invalidate()
        view.feed(text: "\u{1b}[4h")
        #expect(view.withTerminal { $0.insertMode })

        view.resize(cols: 60, rows: 20, softReset: false)
        #expect(view.withTerminal { $0.insertMode })

        view.resize(cols: 50, rows: 20, softReset: true)
        #expect(!view.withTerminal { $0.insertMode })
    }

    @Test func aViewSeesAClipboardWriteWhereItIsParsed() {
        let view = ClipboardWatchingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        view.frameDriver.invalidate()

        view.feed(text: "\u{1b}]52;c;aGVsbG8=\u{07}")

        #expect(view.copied == ["hello".data(using: .utf8)!])
    }
}
#endif
