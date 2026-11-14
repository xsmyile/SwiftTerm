//
//  RenderClock.swift
//  SwiftTerm
//
//  Ticks the render loop at the display cadence without the main thread.
//
//  With the frame driver's display link on the main run loop, every frame
//  started with a main-thread tick that captured the view state and signalled
//  the render loop. The frame itself was off main, but its start was not: with
//  the main thread busy half of each frame, one frame in four was late, about
//  as many as on the main-thread surfaces.
//
//  The clock moves the cadence to a display link on a thread of its own. The
//  render loop draws with the last view state the main thread published, and
//  the main thread publishes only when it changes something.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import QuartzCore

#if os(macOS)
import AppKit
#endif

/// Counters describing how the render clock behaved over a measurement window.
struct RenderClockCounters: Sendable {
    /// Display-link ticks that reached the clock while it ran.
    var ticks = 0
    /// Frames the clock asked the render loop for.
    var frames = 0
    /// Ticks that found nothing to draw.
    var idleTicks = 0
    /// Times the clock stopped its display link after idling.
    var pauses = 0
    /// Frames drawn at once, without waiting for a tick, because the display
    /// link was stopped when the change arrived.
    var immediateFrames = 0
}

/// Where a render clock's ticks come from.
///
/// `start` and `stop` can be called from any thread and must not block. A
/// source may deliver a tick shortly after `stop`; the clock ignores it.
protocol RenderClockSource: AnyObject, Sendable {
    /// Installs the callback the source calls on each tick, before `start`.
    func attach(onTick: @escaping @Sendable () -> Void)
    func start()
    func stop()
    /// Stops for good and releases the display link.
    func invalidate()
}

/// Asks a render loop for frames at the display cadence.
///
/// The same rules as `FrameDriver`, on the clock's own thread: a change marks
/// the clock dirty, the next tick draws it, and after `idleTickLimit` ticks
/// with nothing to draw the display link stops. A change that arrives while
/// it is stopped draws at once, at most once per `minimumResumeInterval`, and
/// starts the link again. Several changes before a tick make one frame.
final class RenderClock: Sendable {
    /// The same idle limit as `FrameDriver.idleTickLimit`.
    static let idleTickLimit = 8
    /// The least time between two frames drawn at once on resume, so a
    /// producer that idles and resumes faster than the display cannot draw
    /// faster than it.
    static let minimumResumeInterval: UInt64 = 16_000_000

    private struct State {
        var dirty = false
        var running = false
        var suspended = false
        var stopped = false
        var idleTicks = 0
        var lastResumeNs: UInt64 = 0
        var counters = RenderClockCounters()
    }

    private let state = Locked(State())
    private let loop: RenderLoop
    private let source: any RenderClockSource
    private let nowNs: @Sendable () -> UInt64

    init (loop: RenderLoop, source: any RenderClockSource,
          nowNs: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.loop = loop
        self.source = source
        self.nowNs = nowNs
        source.attach { [weak self] in self?.sourceDidTick() }
    }

    deinit {
        invalidate()
    }

    /// Asks for a frame with the current terminal content and the last
    /// published view state. Safe from any thread.
    func requestFrame () {
        let drawNow = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.dirty = true
            guard !state.running, !state.suspended else { return false }
            return resume(&state)
        }
        if drawNow {
            loop.signal()
        }
    }

    /// Stops the display link while nothing can see the terminal. A change
    /// recorded meanwhile is drawn when it becomes visible again.
    func setSuspended (_ suspended: Bool) {
        let drawNow = state.withLock { state -> Bool in
            guard !state.stopped, state.suspended != suspended else { return false }
            state.suspended = suspended
            if suspended {
                if state.running {
                    state.running = false
                    source.stop()
                }
                return false
            }
            guard state.dirty, !state.running else { return false }
            return resume(&state)
        }
        if drawNow {
            loop.signal()
        }
    }

    /// Stops the clock for good. Safe from any thread.
    func invalidate () {
        let stop = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.stopped = true
            state.running = false
            state.dirty = false
            return true
        }
        if stop {
            source.invalidate()
        }
    }

    var isRunning: Bool {
        state.withLock { $0.running }
    }

    var isSuspended: Bool {
        state.withLock { $0.suspended }
    }

    var currentCounters: RenderClockCounters {
        state.withLock { $0.counters }
    }

    func resetCounters () {
        state.withLock { $0.counters = RenderClockCounters() }
    }

    /// Starts the link and reports whether the pending change is drawn now
    /// rather than on the first tick.
    private func resume (_ state: inout State) -> Bool {
        state.running = true
        state.idleTicks = 0
        source.start()
        let now = nowNs()
        guard state.lastResumeNs == 0
                || now &- state.lastResumeNs >= Self.minimumResumeInterval else {
            return false
        }
        state.lastResumeNs = now
        state.dirty = false
        state.counters.frames += 1
        state.counters.immediateFrames += 1
        return true
    }

    /// Called by the source on its own thread.
    func sourceDidTick () {
        let draw = state.withLock { state -> Bool in
            guard !state.stopped, state.running else { return false }
            state.counters.ticks += 1
            if state.dirty {
                state.dirty = false
                state.idleTicks = 0
                state.counters.frames += 1
                return true
            }
            state.idleTicks += 1
            state.counters.idleTicks += 1
            if state.idleTicks >= Self.idleTickLimit {
                state.idleTicks = 0
                state.running = false
                state.counters.pauses += 1
                source.stop()
            }
            return false
        }
        if draw {
            loop.signal()
        }
    }
}

/// A tick source driven by hand, for tests.
final class ManualRenderClockSource: RenderClockSource {
    private struct State {
        var onTick: (@Sendable () -> Void)?
        var running = false
        var starts = 0
        var stops = 0
        var invalidated = false
    }
    private let state = Locked(State())

    func attach (onTick: @escaping @Sendable () -> Void) {
        state.withLock { $0.onTick = onTick }
    }

    func start () {
        state.withLock { state in
            guard !state.running, !state.invalidated else { return }
            state.running = true
            state.starts += 1
        }
    }

    func stop () {
        state.withLock { state in
            guard state.running else { return }
            state.running = false
            state.stops += 1
        }
    }

    func invalidate () {
        state.withLock { state in
            state.running = false
            state.invalidated = true
            state.onTick = nil
        }
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }

    /// Delivers one tick on the calling thread when the source runs.
    func tick () {
        let onTick = state.withLock { $0.running ? $0.onTick : nil }
        onTick?()
    }
}

/// The selector target a display link retains.
@available(macOS 14.0, *)
private final class RenderClockLinkTarget: NSObject {
    let onTick: @Sendable () -> Void

    init (onTick: @escaping @Sendable () -> Void) {
        self.onTick = onTick
    }

    @objc func displayLinkFired (_ sender: CADisplayLink) {
        onTick()
    }
}

/// A display link on a thread of its own.
///
/// The link is made on the main thread, which on macOS needs the view it
/// follows, and from then on is only touched on its thread: `start`, `stop`
/// and `invalidate` post to that thread's run loop.
@available(macOS 14.0, *)
final class DisplayLinkRenderClockSource: @unchecked Sendable, RenderClockSource {
    private let tickForwarder = Locked<(@Sendable () -> Void)?>(nil)
    private let runLoop: CFRunLoop
    private let link: CADisplayLink

    /// Makes the link with `makeLink` on the main thread and starts its
    /// thread, paused.
    @MainActor
    init (name: String = "org.tirania.SwiftTerm.render-clock",
          makeLink: (_ target: Any, _ selector: Selector) -> CADisplayLink) {
        let forwarder = tickForwarder
        let target = RenderClockLinkTarget { forwarder.withLock { $0 }?() }
        let link = makeLink(target, #selector(RenderClockLinkTarget.displayLinkFired(_:)))
        link.isPaused = true
        self.link = link

        let ready = DispatchSemaphore(value: 0)
        let loopBox = Locked<CFRunLoop?>(nil)
        let unsafeLink = UnsafeSendableBox(link)
        let thread = Thread {
            let current = CFRunLoopGetCurrent()!
            // A paused link may not count as a run loop input, and a run
            // loop with no input returns at once, so keep one that never fires.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(current, keepAlive, .commonModes)
            unsafeLink.value.add(to: .current, forMode: .common)
            loopBox.withLock { $0 = current }
            ready.signal()
            while CFRunLoopRunInMode(.defaultMode, 1.0e10, false) != .stopped {}
            CFRunLoopRemoveSource(current, keepAlive, .commonModes)
        }
        thread.name = name
        // Same class as the render thread: the tick is the frame's deadline.
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loopBox.withLock { $0 }!
    }

    func attach (onTick: @escaping @Sendable () -> Void) {
        tickForwarder.withLock { $0 = onTick }
    }

    func start () {
        perform { link in link.isPaused = false }
    }

    func stop () {
        perform { link in link.isPaused = true }
    }

    func invalidate () {
        tickForwarder.withLock { $0 = nil }
        perform { link in
            link.invalidate()
            // The block runs on the clock's thread, so this is its run loop.
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func perform (_ body: @escaping @Sendable (CADisplayLink) -> Void) {
        let link = UnsafeSendableBox(self.link)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            body(link.value)
        }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Carries a value that is only used on one thread at a time across a
/// boundary the compiler cannot see.
private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init (_ value: Value) { self.value = value }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
