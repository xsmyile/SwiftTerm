//
//  RenderClockTests.swift
//  SwiftTermTests
//
//  The render clock ticks the render loop from a display link on its own
//  thread, so a busy main thread no longer delays frames. These pin its
//  cadence rules, how the frame driver hands it the work, and that the main
//  thread still publishes every visible change it makes.
//

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct RenderClockTests {
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

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(1000)
        }
        return condition()
    }

    /// A loop that counts frames, and a clock over a hand-driven source.
    private func makeClock(now: Locked<UInt64> = Locked(1_000_000_000))
        -> (RenderClock, ManualRenderClockSource, RenderLoop, FrameCounter)
    {
        let frames = FrameCounter()
        let loop = RenderLoop { frames.increment() }
        loop.start()
        let source = ManualRenderClockSource()
        let clock = RenderClock(loop: loop, source: source, nowNs: { now.withLock { $0 } })
        return (clock, source, loop, frames)
    }

    @Test func requestWhileStoppedDrawsAtOnceAndStartsTheLink() {
        let (clock, source, loop, frames) = makeClock()
        defer { clock.invalidate(); loop.invalidate() }

        clock.requestFrame()

        #expect(source.isRunning)
        #expect(waitUntil { frames.value == 1 })
        #expect(clock.currentCounters.immediateFrames == 1)
    }

    @Test func requestsBeforeATickMakeOneFrame() {
        let (clock, source, loop, frames) = makeClock()
        defer { clock.invalidate(); loop.invalidate() }
        clock.requestFrame()
        #expect(waitUntil { frames.value == 1 })

        for _ in 0..<50 { clock.requestFrame() }
        source.tick()
        source.tick()

        #expect(waitUntil { frames.value == 2 })
        usleep(20_000)
        #expect(frames.value == 2)
        #expect(clock.currentCounters.frames == 2)
    }

    @Test func idleTicksStopTheLink() {
        let (clock, source, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate() }
        clock.requestFrame()

        for _ in 0..<RenderClock.idleTickLimit { source.tick() }

        #expect(!source.isRunning)
        #expect(!clock.isRunning)
        #expect(clock.currentCounters.pauses == 1)
    }

    /// A producer that idles and resumes faster than the display gets its
    /// next frame from the tick, not at once.
    @Test func immediateFramesAreRateLimited() {
        let now = Locked<UInt64>(1_000_000_000)
        let (clock, source, loop, frames) = makeClock(now: now)
        defer { clock.invalidate(); loop.invalidate() }
        clock.requestFrame()
        #expect(waitUntil { frames.value == 1 })
        for _ in 0..<RenderClock.idleTickLimit { source.tick() }

        now.withLock { $0 += 5_000_000 }
        clock.requestFrame()
        usleep(20_000)
        #expect(frames.value == 1)
        #expect(source.isRunning)
        source.tick()
        #expect(waitUntil { frames.value == 2 })
        #expect(clock.currentCounters.immediateFrames == 1)
    }

    @Test func suspendedClockRecordsAndDrawsWhenVisibleAgain() {
        let now = Locked<UInt64>(1_000_000_000)
        let (clock, source, loop, frames) = makeClock(now: now)
        defer { clock.invalidate(); loop.invalidate() }
        clock.requestFrame()
        #expect(waitUntil { frames.value == 1 })

        clock.setSuspended(true)
        #expect(!source.isRunning)
        for _ in 0..<20 { clock.requestFrame() }
        source.tick()
        usleep(20_000)
        #expect(frames.value == 1)
        #expect(!source.isRunning)

        now.withLock { $0 += RenderClock.minimumResumeInterval }
        clock.setSuspended(false)
        #expect(source.isRunning)
        #expect(waitUntil { frames.value == 2 })
    }

    @Test func noFrameAfterInvalidate() {
        let (clock, source, loop, frames) = makeClock()
        defer { loop.invalidate() }
        clock.invalidate()

        clock.requestFrame()
        source.tick()
        usleep(20_000)
        #expect(frames.value == 0)
        #expect(!source.isRunning)
    }

    /// With a clock attached, a dirty mark from another thread reaches the
    /// clock directly: no main-actor task, however many marks.
    @Test func backgroundMarksReachTheClockWithoutAMainTask() async {
        let driver = FrameDriver(tickSource: ManualTickSource())
        var ticks = 0
        driver.onTick = { ticks += 1 }
        let (clock, source, loop, frames) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)
        driver.resetCounters()

        let signal = driver.signal
        await Task.detached {
            for _ in 0..<1000 { signal.markDirty() }
        }.value
        await drainMainQueue()

        #expect(driver.currentCounters.deliveries == 0)
        #expect(ticks == 0)
        // The first mark draws at once; the rest wait for one tick.
        #expect(waitUntil { frames.value == 1 })
        source.tick()
        #expect(waitUntil { frames.value == 2 })
        source.tick()
        #expect(waitUntil(timeout: 0.1) { frames.value == 3 } == false)
    }

    /// A mark made on main can be a change to the view state, so it runs one
    /// main-thread tick, which publishes it, however many marks main made.
    @Test func mainThreadMarksRunOneTickPerTurn() async {
        let tickSource = ManualTickSource()
        let driver = FrameDriver(tickSource: tickSource)
        var ticks = 0
        driver.onTick = { ticks += 1 }
        let (clock, _, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)

        for _ in 0..<10 { driver.markDirty() }
        await drainMainQueue()

        #expect(ticks == 1)
        #expect(!tickSource.isRunning)
        #expect(driver.currentCounters.deliveries == 1)
    }

    /// A view update from another thread runs on main, and its dirty mark
    /// goes to the clock: main does not tick for it, so a program that ends
    /// synchronized output on every frame does not get each frame drawn twice.
    @Test func viewUpdatesRunOnMainAndTheirMarkGoesToTheClock() async {
        let driver = FrameDriver(tickSource: ManualTickSource())
        var order: [String] = []
        driver.onViewUpdate = { order.append("update") }
        driver.onTick = { order.append("tick") }
        let (clock, _, loop, frames) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)

        let signal = driver.signal
        await Task.detached { signal.requestViewUpdate() }.value
        await drainMainQueue()

        #expect(order == ["update"])
        #expect(waitUntil { frames.value == 1 })
    }

    /// A program that ends synchronized output on every frame sends a view
    /// update per frame. While the clock's link runs they wait for its tick,
    /// and one tick posts one main-actor task for all of them, as the main
    /// link's tick did.
    /// After main publishes a change, its frame is drawn at once unless one
    /// was already drawn since the last tick: one tick and at most one such
    /// frame per display period.
    @Test func framesMainAsksForDrawSoonButOncePerTick() {
        let (clock, source, loop, frames) = makeClock()
        defer { clock.invalidate(); loop.invalidate() }
        clock.requestFrame()
        #expect(waitUntil { frames.value == 1 })

        clock.requestFrame(soon: true)
        usleep(20_000)
        #expect(frames.value == 1)

        source.tick()
        #expect(waitUntil { frames.value == 2 })
        clock.requestFrame(soon: true)
        clock.requestFrame(soon: true)
        usleep(20_000)
        #expect(frames.value == 2)

        source.tick()
        #expect(waitUntil { frames.value == 3 })
        source.tick()
        clock.requestFrame(soon: true)
        #expect(waitUntil { frames.value == 4 })
        clock.requestFrame(soon: true)
        usleep(20_000)
        #expect(frames.value == 4)
    }

    @Test func viewUpdatesWaitForTheClockTick() async {
        let driver = FrameDriver(tickSource: ManualTickSource())
        var updates = 0
        driver.onViewUpdate = { updates += 1 }
        driver.onTick = {}
        let (clock, source, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)
        clock.requestFrame()
        #expect(source.isRunning)
        driver.resetCounters()

        let signal = driver.signal
        await Task.detached {
            for _ in 0..<200 { signal.requestViewUpdate() }
        }.value
        await drainMainQueue()
        #expect(driver.currentCounters.deliveries == 0)
        #expect(updates == 0)

        source.tick()
        await drainMainQueue()
        #expect(driver.currentCounters.deliveries == 1)
        #expect(updates == 1)

        source.tick()
        await drainMainQueue()
        #expect(driver.currentCounters.deliveries == 1)
    }

    /// A view update waiting for a tick is delivered when the link stops
    /// instead, so it is never stranded.
    @Test func waitingViewUpdatesAreDeliveredWhenTheClockStops() async {
        let driver = FrameDriver(tickSource: ManualTickSource())
        var updates = 0
        driver.onViewUpdate = { updates += 1 }
        driver.onTick = {}
        let (clock, source, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)
        clock.requestFrame()

        let signal = driver.signal
        await Task.detached { signal.requestViewUpdate() }.value
        await drainMainQueue()
        #expect(updates == 0)

        driver.setVisibilityOnMain(visible: false)
        await drainMainQueue()
        #expect(!source.isRunning)
        #expect(updates == 1)

        driver.setVisibilityOnMain(visible: true)
        clock.requestFrame()
        await Task.detached { signal.requestViewUpdate() }.value
        for _ in 0..<RenderClock.idleTickLimit { source.tick() }
        await drainMainQueue()
        #expect(updates == 2)
    }

    @Test func visibilitySuspendsTheClock() async {
        let tickSource = ManualTickSource()
        let driver = FrameDriver(tickSource: tickSource)
        let (clock, source, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)
        clock.requestFrame()
        #expect(source.isRunning)

        driver.setVisibilityOnMain(visible: false)
        #expect(clock.isSuspended)
        #expect(!source.isRunning)
        #expect(!tickSource.isRunning)

        driver.setVisibilityOnMain(visible: true)
        #expect(!clock.isSuspended)
    }

    /// Detaching the clock gives the cadence back to the driver's own link.
    @Test func detachingTheClockRestoresTheMainLink() async {
        let tickSource = ManualTickSource()
        let driver = FrameDriver(tickSource: tickSource)
        var ticks = 0
        driver.onTick = { ticks += 1 }
        let (clock, _, loop, _) = makeClock()
        defer { clock.invalidate(); loop.invalidate(); driver.invalidate() }
        driver.attachRenderClock(clock)
        driver.attachRenderClock(nil)

        driver.markDirty()
        await drainMainQueue()
        #expect(tickSource.isRunning)
        #expect(ticks == 1)
    }

    /// The point of the clock: frames keep coming while the main thread is
    /// busy and its run loop does not turn. A real display link, on the
    /// built-in display when there is one; no window.
    @available(macOS 14.0, *)
    @Test func framesContinueWhileTheMainThreadIsBusy() throws {
        let screen = try #require(NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.screens.first)
        let frames = FrameCounter()
        let loop = RenderLoop { frames.increment() }
        loop.start()
        let source = DisplayLinkRenderClockSource { target, selector in
            screen.displayLink(target: target, selector: selector)
        }
        let clock = RenderClock(loop: loop, source: source)
        defer { clock.invalidate(); loop.invalidate() }

        let stop = Locked(false)
        let producer = Thread {
            while !stop.withLock({ $0 }) {
                clock.requestFrame()
                usleep(2000)
            }
        }
        producer.start()
        defer { stop.withLock { $0 = true } }

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {}
        let drawnWhileBusy = frames.value
        stop.withLock { $0 = true }

        // At least 60 Hz for half a second, with slack for a loaded machine.
        #expect(drawnWhileBusy >= 15)
        #expect(clock.currentCounters.ticks >= 15)
    }

    // MARK: The terminal view

    private func makeWindowedView() -> (NSWindow, TerminalView) {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: frame)
        window.contentView = view
        // Test windows are never ordered in, so the occlusion pause is off;
        // the clock's own pause is covered above.
        view.suspendsRenderingWhenNotVisible = false
        return (window, view)
    }

    /// Lets a change made on main reach the published view state: it waits
    /// for a clock tick, and some setters mark the frame from a later main
    /// turn.
    private func settle(_ source: ManualRenderClockSource) async {
        for _ in 0..<2 {
            source.tick()
            await drainMainQueue()
        }
    }

    /// Swaps the view's clock for one driven by hand: a window that is never
    /// ordered in gets no display-link ticks.
    private func useManualClock(_ view: TerminalView) throws -> ManualRenderClockSource {
        let loop = try #require(view.renderLoop)
        let source = ManualRenderClockSource()
        let old = view.frameDriver.renderClock
        view.frameDriver.attachRenderClock(RenderClock(loop: loop, source: source))
        old?.invalidate()
        return source
    }

    @available(macOS 14.0, *)
    @Test(.enabled(if: RenderClockTests.metalIsUsable))
    func theLayerSurfaceTakesItsCadenceFromTheClock() throws {
        let (window, view) = makeWindowedView()
        defer {
            _ = view.updateUiClosed()
            window.close()
        }
        try view.setUseMetal(true)
        #expect(view.isUsingRenderLoop)
        #expect(view.frameDriver.renderClock != nil)

        try view.setUsesMetalLayerSurface(false)
        #expect(view.frameDriver.renderClock == nil)
        try view.setUsesMetalLayerSurface(true)
        #expect(view.frameDriver.renderClock != nil)

        try view.setUseMetal(false)
        #expect(view.frameDriver.renderClock == nil)
    }

    /// Output keeps reaching the screen while the main thread is busy: the
    /// parse thread marks the frame dirty, the clock's thread ticks, and the
    /// render thread draws, with no main-thread turn in between.
    @available(macOS 14.0, *)
    @Test(.enabled(if: RenderClockTests.metalIsUsable))
    func outputIsDrawnWhileTheMainThreadIsBusy() async throws {
        let (window, view) = makeWindowedView()
        defer {
            _ = view.updateUiClosed()
            window.close()
        }
        try view.setUseMetal(true)
        let source = try useManualClock(view)
        await drainMainQueue()
        view.renderOwner.resetMetalCounters()

        let stop = Locked(false)
        let sender = view.feedSender
        let feeder = Thread {
            var line = 0
            while !stop.withLock({ $0 }) {
                line += 1
                sender.feed(text: "line \(line)\r\n")
                source.tick()
                usleep(4000)
            }
        }
        feeder.start()
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {}
        let drawnWhileBusy = view.renderOwner.completedMetalRenders
        stop.withLock { $0 = true }

        #expect(drawnWhileBusy >= 10)
    }

    private struct CapturedSetter {
        let name: String
        let set: @MainActor (TerminalView) -> Void
        let read: (FrameViewState) -> String
    }

    /// Every setter of an input the frame captures, with the published value
    /// it must change. With a render clock nothing on main captures the view
    /// state per frame, so a setter that forgot its dirty mark would only be
    /// drawn after some unrelated change on main.
    private static let capturedSetters: [CapturedSetter] = [
        CapturedSetter(name: "caretColor", set: { $0.caretColor = .systemPink },
                       read: { "\($0.caretColor)" }),
        CapturedSetter(name: "caretTextColor", set: { $0.caretTextColor = .systemTeal },
                       read: { "\($0.caretTextColor)" }),
        CapturedSetter(name: "metalBufferingMode", set: { $0.metalBufferingMode = .perFrameAggregated },
                       read: { "\($0.metalBufferingMode)" }),
        CapturedSetter(name: "fontSmoothing", set: { $0.fontSmoothing.toggle() },
                       read: { "\($0.fontSmoothing)" }),
        CapturedSetter(name: "notifyUpdateChanges", set: { $0.notifyUpdateChanges.toggle() },
                       read: { "\($0.notifyUpdateChanges)" }),
        CapturedSetter(name: "nativeForegroundColor", set: { $0.nativeForegroundColor = .systemOrange },
                       read: { "\($0.effectiveForegroundColor)" }),
        CapturedSetter(name: "nativeBackgroundColor", set: { $0.nativeBackgroundColor = .systemIndigo },
                       read: { "\($0.effectiveBackgroundColor)" }),
        CapturedSetter(name: "selectedTextBackgroundColor", set: { $0.selectedTextBackgroundColor = .systemBrown },
                       read: { "\($0.selectedTextBackgroundColor)" }),
        CapturedSetter(name: "selectedTextForegroundColor", set: { $0.selectedTextForegroundColor = .systemMint },
                       read: { "\($0.selectedTextForegroundColor)" }),
        CapturedSetter(name: "linkColor", set: { $0.linkColor = .systemGreen },
                       read: { "\(String(describing: $0.linkColor as Any))" }),
        CapturedSetter(name: "linkUnderlineColor", set: { $0.linkUnderlineColor = .systemRed },
                       read: { "\(String(describing: $0.linkUnderlineColor as Any))" }),
        CapturedSetter(name: "linkHighlightMode", set: { $0.linkHighlightMode = .always },
                       read: { "\($0.linkHighlightMode)" }),
        CapturedSetter(name: "commandActive", set: { $0.commandActive.toggle() },
                       read: { "\($0.commandActive)" }),
        CapturedSetter(name: "linkHighlightRange",
                       set: { $0.linkHighlightRange = [.init(row: 0, range: 0..<4)] },
                       read: { "\($0.linkHighlightRange as Any)" }),
        CapturedSetter(name: "textBlinkVisible", set: { $0.textBlinkVisible.toggle() },
                       read: { "\($0.textBlinkVisible)" }),
        CapturedSetter(name: "antiAliasCustomBlockGlyphs", set: { $0.antiAliasCustomBlockGlyphs.toggle() },
                       read: { "\($0.antiAliasCustomBlockGlyphs)" }),
        CapturedSetter(name: "customBlockGlyphs", set: { $0.customBlockGlyphs.toggle() },
                       read: { "\($0.customBlockGlyphs)" }),
        CapturedSetter(name: "useBrightColors", set: { $0.useBrightColors.toggle() },
                       read: { "\($0.useBrightColors)" }),
        CapturedSetter(name: "collapseBrightColorsToBase", set: { $0.collapseBrightColorsToBase.toggle() },
                       read: { "\($0.collapseBrightColorsToBase)" }),
        CapturedSetter(name: "minimumContrastRatio", set: { $0.minimumContrastRatio = 4.5 },
                       read: { "\($0.minimumContrastRatio)" }),
        CapturedSetter(name: "translucentCellBackgrounds", set: { $0.translucentCellBackgrounds.toggle() },
                       read: { "\($0.translucentCellBackgrounds)" }),
        CapturedSetter(name: "bidiHostPolicy", set: { $0.bidiHostPolicy = .legacyLeftToRight },
                       read: { "\($0.bidiHostPolicy)" }),
        CapturedSetter(name: "caretViewTracksFocus", set: { $0.caretViewTracksFocus.toggle() },
                       read: { "\($0.cursorHasFocus)" }),
        CapturedSetter(name: "font", set: { $0.font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular) },
                       read: { "\($0.cellDimension.width)x\($0.cellDimension.height)" }),
        CapturedSetter(name: "metalScaleFactorOverride", set: { $0.metalScaleFactorOverride = 3 },
                       read: { "\($0.renderingScale)" }),
    ]

    /// Each setter publishes its change for the next frame while only the
    /// clock and background output drive frames.
    @available(macOS 14.0, *)
    @Test(.enabled(if: RenderClockTests.metalIsUsable),
          arguments: 0..<25)
    func capturedSettersReachTheNextFrame(index: Int) async throws {
        #expect(Self.capturedSetters.count == 25)
        let setter = Self.capturedSetters[index]
        let (window, view) = makeWindowedView()
        defer {
            _ = view.updateUiClosed()
            window.close()
        }
        try view.setUseMetal(true)
        let source = try useManualClock(view)
        await drainMainQueue()
        let mailbox = view.renderOwner.mailbox
        let before = setter.read(try #require(mailbox.publishedViewState))

        setter.set(view)
        await settle(source)
        let sender = view.feedSender
        await Task.detached {
            sender.feed(text: "background output\r\n")
            source.tick()
        }.value

        let after = setter.read(try #require(mailbox.publishedViewState))
        #expect(after != before, "\(setter.name) did not reach the published view state")
    }

    /// End to end with the default clock: a window on the built-in display,
    /// never key or front, output fed from another thread, and the main
    /// thread stalled. Frames keep completing during the stall.
    @available(macOS 14.0, *)
    @Test(.enabled(if: RenderClockTests.metalIsUsable && RenderClockTests.hasBuiltInDisplay))
    func defaultClockPresentsFramesDuringAMainStall() throws {
        let screen = try #require(Self.builtInScreen)
        let displayID = try #require(Self.displayID(screen))
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40,
                           width: 480, height: 300)
        let window = NeverKeyWindow(contentRect: NSRect(origin: .zero, size: frame.size),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        try #require(screen.frame.contains(window.frame))
        let view = TerminalView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
        view.suspendsRenderingWhenNotVisible = false
        try view.setUseMetal(true)
        window.orderBack(nil)
        defer {
            _ = view.updateUiClosed()
            window.orderOut(nil)
            window.close()
        }
        #expect(view.frameDriver.renderClock != nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try #require(Self.window(window.windowNumber, isOn: displayID))

        let presented = Locked(0)
        TerminalView.onFramePresented = { presented.withLock { $0 += 1 } }
        defer { TerminalView.onFramePresented = nil }
        let stop = Locked(false)
        let sender = view.feedSender
        let feeder = Thread {
            var line = 0
            while !stop.withLock({ $0 }) {
                line += 1
                sender.feed(text: "line \(line) of output fed while main is busy\r\n")
                usleep(2000)
            }
        }
        feeder.start()
        defer { stop.withLock { $0 = true } }

        presented.withLock { $0 = 0 }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {}
        let duringStall = presented.withLock { $0 }
        stop.withLock { $0 = true }

        #expect(duringStall >= 15)
    }

    private final class NeverKeyWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A built-in display is attached (not with the lid closed).
    nonisolated static var hasBuiltInDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            displayID(screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// True when the window server puts the window inside the display.
    static func window(_ number: Int, isOn display: CGDirectDisplayID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number))
                as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return CGDisplayBounds(display).contains(rect)
    }

    /// The rule the clock relies on: a visible change made on main marks the
    /// frame dirty, and that mark publishes the new view state before the
    /// frame that shows it. A setter that changed the view without marking
    /// would be drawn late or never.
    @available(macOS 14.0, *)
    @Test(.enabled(if: RenderClockTests.metalIsUsable))
    func visibleChangesOnMainArePublishedForTheNextFrame() async throws {
        let (window, view) = makeWindowedView()
        defer {
            _ = view.updateUiClosed()
            window.close()
        }
        try view.setUseMetal(true)
        let source = try useManualClock(view)
        view.feed(text: "published view state\r\n")
        await drainMainQueue()
        let mailbox = view.renderOwner.mailbox
        let before = try #require(mailbox.publishedViewState)

        view.font = NSFont.monospacedSystemFont(ofSize: 23, weight: .regular)
        await settle(source)
        let afterFont = try #require(mailbox.publishedViewState)
        #expect(afterFont.cellDimension.height > before.cellDimension.height)

        view.nativeForegroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        await settle(source)
        let afterColor = try #require(mailbox.publishedViewState)
        #expect(afterColor.effectiveForegroundColor != afterFont.effectiveForegroundColor)

        view.selectAll(nil)
        await settle(source)
        #expect(waitUntil { view.renderOwner.inspection().selectionActive })
    }
}

/// A lock-guarded frame counter the render thread writes and the test reads.
private final class FrameCounter: Sendable {
    private let count = Locked(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment () {
        count.withLock { $0 += 1 }
    }
}
#endif
