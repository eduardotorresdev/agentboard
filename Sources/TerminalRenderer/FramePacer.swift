/// Decides how often a board of terminals draws and which changed terminals go into each frame.
///
/// Most of a frame's cost is fixed: waking up, submitting to the GPU, presenting. Drawing a
/// terminal's cells is cheap next to it. So the pacer keeps frames few: it lowers the frame rate
/// when nobody is interacting, and it gathers the terminals in the background into shared frames.
public struct FramePacer<ID: Hashable> {
    public enum Pace: Equatable {
        /// Right after the user types, clicks or scrolls: the echo shows at once.
        case interactive
        /// The focused terminal is printing. Only one terminal is focused, so it reads along at
        /// 60 Hz; when the board is `crowded` (many terminals printing) it drops to 30 Hz.
        case focused(crowded: Bool)
        /// Only terminals in the background are changing: they update together, a few times a second.
        case background

        /// The display refresh rate to ask for, in frames per second.
        public var frameRate: (minimum: Float, maximum: Float, preferred: Float) {
            switch self {
            case .interactive: (60, 120, 120)
            case .focused(crowded: false): (30, 60, 60)
            case .focused(crowded: true): (20, 30, 30)
            case .background: (10, 15, 15)
            }
        }
    }

    /// The terminal the user is following; it draws on every refresh.
    public var focused: ID?
    /// Other terminals draw at most this often.
    public var backgroundInterval: Double
    /// When a frame is drawn anyway (for the focused terminal), background terminals at least
    /// this far into their interval ride along instead of costing a frame of their own later.
    /// 1 turns riding along off.
    public var rideAlong: Double
    /// More terminals than this printing at once make the board crowded.
    public var crowdLimit: Int
    /// A terminal counts as printing for this long after its last change.
    public var printingWindow = 1.0
    private var interactiveUntil = -Double.infinity
    private var focusedActiveUntil = -Double.infinity
    private var lastBackgroundDraw = -Double.infinity
    private var lastChange: [ID: Double] = [:]

    public init(backgroundInterval: Double = 1.0 / 15, rideAlong: Double = 0.4, crowdLimit: Int = 3) {
        self.backgroundInterval = backgroundInterval
        self.rideAlong = rideAlong
        self.crowdLimit = crowdLimit
    }

    /// The user acted on the board.
    public mutating func interacted(at now: Double) {
        interactiveUntil = now + 0.5
    }

    public func pace(at now: Double) -> Pace {
        now < interactiveUntil ? .interactive : now < focusedActiveUntil ? .focused(crowded: printing(at: now) > crowdLimit) : .background
    }

    /// How many terminals changed within the last `printingWindow`.
    public func printing(at now: Double) -> Int {
        lastChange.values.reduce(0) { $0 + (now - $1 < printingWindow ? 1 : 0) }
    }

    /// Splits the terminals that changed into the ones to draw now and the ones to keep for a
    /// later frame, and records the draw.
    public mutating func select(_ dirty: Set<ID>, at now: Double) -> (draw: [ID], wait: Set<ID>) {
        let drawsFocused = focused.map(dirty.contains) ?? false
        let elapsed = now - lastBackgroundDraw
        // A little slack so a 15 Hz refresh doesn't miss the beat by a hair.
        let backgroundDue = elapsed >= backgroundInterval * 0.8 || (drawsFocused && elapsed >= backgroundInterval * rideAlong)
        var draw: [ID] = []
        var wait = Set<ID>()
        for id in dirty {
            lastChange[id] = now
            if id == focused || backgroundDue { draw.append(id) } else { wait.insert(id) }
        }
        if drawsFocused { focusedActiveUntil = now + 0.5 }
        if lastChange.count > 4 * max(crowdLimit, 1) { lastChange = lastChange.filter { now - $0.value < printingWindow } }
        if backgroundDue && draw.contains(where: { $0 != focused }) { lastBackgroundDraw = now }
        return (draw, wait)
    }
}
