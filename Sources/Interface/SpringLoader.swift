import AppKit
import Base
import Browser

/// Finder's spring-loaded folders for one pane's lists: a drag that hovers over a folder row for
/// the system's spring-loading delay opens the folder, in the list or as its column
/// (`Pane.springOpen`), and Space or a force click opens it at once. Leaving the row first opens
/// nothing. Once the drag ends, dropped or not, the pane goes back to where it was
/// (`Pane.springBack`). The lists say which row the drag is over from the listing alone, so
/// deciding reads nothing from the disk (docs/decisions/0099-get-info-and-spring-loading.md).
@MainActor
final class SpringLoader {
    /// A folder row a drag is over: the folder `name` in `pane`'s folder at `location`.
    struct Target: Equatable {
        let pane: Pane
        let location: Location
        let name: String

        static func == (a: Target, b: Target) -> Bool {
            a.pane === b.pane && a.location == b.location && a.name == b.name
        }
    }

    /// How often, after a spring, the loader checks whether the mouse button is still down, to
    /// learn of a drag that ended away from the pane's lists, where no list hears of it.
    static let mouseCheckInterval: Duration = .milliseconds(100)

    /// The row the drag is over now; nil when it is over no row that springs.
    private(set) var target: Target?
    /// The wait for the delay on `target`; nil once it has sprung or while there is no target.
    private var wait: Task<Void, Never>?
    /// The pane a spring of this drag opened a folder in, to go back once the drag ends.
    private var sprung: Pane?
    /// Whether the drag is over one of the pane's lists, which hear of its end themselves.
    private var isOverList = false
    /// Checks the mouse button while a spring waits to go back and no list has the drag.
    private var mouseCheck: Task<Void, Never>?

    /// The delay, or nil while the system's Spring-loading setting is off.
    private let delay: @MainActor () -> Duration?
    /// Whether the mouse button is down, as a drag holds it.
    private let isMouseDown: @MainActor () -> Bool
    /// Starts a wait of the given length on the clock, taking the deadline at once.
    private let startWait: DeadlineWait.Start

    /// `delay` reads the system setting, through `Settings.springLoadingDelay`. Tests pass a
    /// clock they advance and a mouse they press.
    init<C: Clock<Duration>>(
        delay: @escaping @MainActor () -> Duration?,
        clock: C = ContinuousClock(),
        isMouseDown: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    ) {
        self.delay = delay
        self.isMouseDown = isMouseDown
        startWait = DeadlineWait.make(on: clock)
    }

    /// What AppKit's spring loading may do over the row the drag is over: activate on Space or a
    /// force click, which AppKit reports to `activate`, while the drag is over a row that springs
    /// and the setting is on. Hovering is timed here per row, since AppKit times it per view.
    var options: NSSpringLoadingOptions {
        target != nil && delay() != nil ? [.enabled, .noHover] : []
    }

    /// The drag is over `target`, or over no row that springs when it is nil: a new row starts
    /// the delay again, and the row it has been over keeps its wait. `info` is told of a new row,
    /// so AppKit's own spring loading starts again for it.
    func hover(over target: Target?, info: any NSDraggingInfo) {
        isOverList = true
        guard target != self.target else { return }
        clearTarget()
        self.target = target
        info.resetSpringLoading()
        guard let target, let delay = delay() else { return }
        let sleep = startWait(delay)
        wait = Task { [weak self] in
            guard await DeadlineWait.reached(sleep) else { return }
            guard let self, !Task.isCancelled, self.target == target else { return }
            spring(target)
        }
    }

    /// The drag left one of `pane`'s lists: a row of that list no longer springs. A drag that
    /// moves to another column has left one list before it reaches the next.
    func dragExited(_ pane: Pane) {
        isOverList = false
        if target?.pane === pane {
            clearTarget()
        }
        watchMouse()
    }

    /// Space or a force click: the row the drag is over springs now.
    func activate() {
        guard let target, wait != nil else { return }
        wait?.cancel()
        spring(target)
    }

    /// The drag ended over one of the pane's lists, after its drop if it made one: the pane goes
    /// back.
    func dragEnded() {
        clearTarget()
        isOverList = false
        mouseCheck?.cancel()
        mouseCheck = nil
        let pane = sprung
        sprung = nil
        pane?.springBack()
    }

    private func clearTarget() {
        wait?.cancel()
        wait = nil
        target = nil
    }

    private func spring(_ target: Target) {
        wait = nil
        target.pane.springOpen(target.name)
        sprung = target.pane
    }

    /// After a spring, while the drag is over none of the pane's lists, goes back once the mouse
    /// button is up: a drag that ends elsewhere sends no list its end.
    private func watchMouse() {
        guard sprung != nil, mouseCheck == nil else { return }
        let startWait = startWait
        mouseCheck = Task { [weak self] in
            while !Task.isCancelled, self?.endIfMouseIsUp() == false {
                guard await DeadlineWait.reached(startWait(Self.mouseCheckInterval)) else { return }
            }
        }
    }

    /// Ends the drag if it is over none of the pane's lists and the mouse button is up, and
    /// returns whether it did.
    private func endIfMouseIsUp() -> Bool {
        guard !isOverList, !isMouseDown() else { return false }
        mouseCheck = nil
        dragEnded()
        return true
    }
}
