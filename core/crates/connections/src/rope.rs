use crate::{Point, Side, Vector};

/// A connection's path on the board, from its first element's card to its second's.
#[derive(Clone, Debug, PartialEq)]
pub struct Route {
    pub points: Vec<Point>,
}

fn distance(a: Point, b: Point) -> f64 {
    (b.x - a.x).hypot(b.y - a.y)
}

impl Route {
    pub fn new(points: Vec<Point>) -> Self {
        Self { points }
    }

    pub fn length(&self) -> f64 {
        self.points.windows(2).map(|pair| distance(pair[0], pair[1])).sum()
    }

    /// The point `fraction` (0…1) of the way along the route.
    pub fn point_at(&self, fraction: f64) -> Point {
        let mut remaining = self.length() * fraction.clamp(0.0, 1.0);
        for pair in self.points.windows(2) {
            let (start, end) = (pair[0], pair[1]);
            let segment = distance(start, end);
            if remaining <= segment && segment > 0.0 {
                let t = remaining / segment;
                return Point::new(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
            }
            remaining -= segment;
        }
        self.points.last().copied().unwrap_or(Point::ZERO)
    }

    /// The shortest distance from `point` to the route.
    pub fn distance_to(&self, point: Point) -> f64 {
        if self.points.len() < 2 {
            return self.points.first().map_or(f64::INFINITY, |only| distance(*only, point));
        }
        let to_segment = |pair: &[Point]| {
            let (start, end) = (pair[0], pair[1]);
            let (dx, dy) = (end.x - start.x, end.y - start.y);
            let squared = dx * dx + dy * dy;
            let t = if squared > 0.0 { (((point.x - start.x) * dx + (point.y - start.y) * dy) / squared).clamp(0.0, 1.0) } else { 0.0 };
            (start.x + dx * t - point.x).hypot(start.y + dy * t - point.y)
        };
        self.points.windows(2).map(to_segment).fold(f64::INFINITY, f64::min)
    }

    pub fn reversed(&self) -> Route {
        Route::new(self.points.iter().rev().copied().collect())
    }
}

impl Side {
    /// The way out of a card through this side, in board coordinates (y grows downward).
    pub fn outward(self) -> Vector {
        match self {
            Side::Top => Vector::new(0.0, -1.0),
            Side::Right => Vector::new(1.0, 0.0),
            Side::Bottom => Vector::new(0.0, 1.0),
            Side::Left => Vector::new(-1.0, 0.0),
        }
    }
}

/// Where a rope is tied: a point, and the direction the rope leaves it in, like a cable out of
/// its plug (zero for a loose end, such as one held by the pointer).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RopeAnchor {
    pub point: Point,
    pub direction: Vector,
}

impl RopeAnchor {
    pub fn new(point: Point, direction: Vector) -> Self {
        Self { point, direction }
    }

    pub fn side(point: Point, side: Side) -> Self {
        Self::new(point, side.outward())
    }
}

/// A line between two cards that hangs like a rope: a chain of particles under gravity (Verlet
/// integration), held a fixed distance apart. The chain hangs from a point a little way out of
/// each card; from the card to the chain the line leaves straight out of its side, like a cable
/// out of a plug, and bends into the chain on its tangent. It swings when an end moves until it
/// comes to rest.
///
/// The rope's length follows its ends: a little longer than the distance between them, so it
/// always hangs slack. When the ends move apart faster than it grows, it stretches taut and
/// springs back.
#[derive(Clone, Debug)]
pub struct Rope {
    chain: Vec<Point>,
    previous: Vec<Point>,
    rest_length: f64,
    anchors: (RopeAnchor, RopeAnchor),
    /// Seconds of simulation owed to the clock, under one step.
    owed: f64,
    /// Steps in a row nothing moved.
    calm: usize,
    is_settled: bool,
}

impl Rope {
    const PARTICLES: usize = 41;
    /// Points per second squared.
    const GRAVITY: f64 = 1600.0;
    const TIMESTEP: f64 = 1.0 / 120.0;
    const ITERATIONS: usize = 16;
    /// Velocity kept per step.
    const DAMPING: f64 = 0.982;
    /// Extra length, as a fraction of the span, that makes the rope sag.
    const SLACK: f64 = 0.07;
    /// How far out of a card the line runs before the chain hangs, at most.
    const MAXIMUM_LEAD: f64 = 22.0;
    /// How fast the rope's length catches up with its ends, per step.
    const GROWTH: f64 = 0.12;
    /// Movement, in points per step, below which the rope counts as still.
    const STILLNESS: f64 = 0.01;

    pub fn new(a: RopeAnchor, b: RopeAnchor) -> Self {
        let (start, end) = Self::hanging_points(a, b);
        let chain: Vec<Point> = if distance(start, end) < 1.0 {
            // Ends together (a line starting to be drawn): bunched up, ready to fall.
            (0..Self::PARTICLES).map(|index| Point::new(start.x, start.y + index as f64 * 0.5)).collect()
        } else {
            // Laid out along a curve leaving each end in its direction; gravity takes it from there.
            let lead = Self::lead(a, b);
            let c1 = Point::new(start.x + a.direction.dx * lead, start.y + a.direction.dy * lead);
            let c2 = Point::new(end.x + b.direction.dx * lead, end.y + b.direction.dy * lead);
            (0..Self::PARTICLES).map(|index| bezier(start, c1, c2, end, index as f64 / (Self::PARTICLES - 1) as f64)).collect()
        };
        Self { previous: chain.clone(), chain, rest_length: Self::length(start, end), anchors: (a, b), owed: 0.0, calm: 0, is_settled: false }
    }

    /// A rope already hanging at rest between `a` and `b`, for lines that are just there (the
    /// board opening) rather than drawn.
    pub fn resting(a: RopeAnchor, b: RopeAnchor) -> Rope {
        let mut rope = Rope::new(a, b);
        for _ in 0..1200 {
            if !rope.is_settled {
                rope.step();
            }
        }
        rope.previous = rope.chain.clone();
        rope.is_settled = true;
        rope
    }

    pub fn is_settled(&self) -> bool {
        self.is_settled
    }

    /// The line as drawn, from the first anchor to the second.
    pub fn points(&self) -> Vec<Point> {
        let last = self.chain.len() - 1;
        // Where the plugs blend into the chain: past the droop by its hanging points.
        let (a, b) = self.anchors;
        let reach = Self::lead(a, b) * 2.0;
        let join_a = if a.direction == Vector::ZERO { 0 } else { self.join(0, 1, reach) };
        let join_b = if b.direction == Vector::ZERO { last } else { self.join(last, -1, reach) };
        if join_a >= join_b {
            return [&[a.point], self.chain.as_slice(), &[b.point]].concat();
        }
        let head = if a.direction == Vector::ZERO { vec![a.point] } else { self.plug(a, join_a, 1) };
        let mut tail = if b.direction == Vector::ZERO { vec![b.point] } else { self.plug(b, join_b, -1) };
        tail.reverse();
        [head.as_slice(), &self.chain[join_a + 1..join_b], tail.as_slice()].concat()
    }

    pub fn route(&self) -> Route {
        Route::new(self.points())
    }

    /// Moves the rope's ends to `a` and `b`; it wakes up if they changed.
    pub fn tie(&mut self, a: RopeAnchor, b: RopeAnchor) {
        if close(a, self.anchors.0) && close(b, self.anchors.1) {
            return;
        }
        self.anchors = (a, b);
        self.is_settled = false;
        self.calm = 0;
    }

    /// Runs the simulation `seconds` forward, in fixed steps.
    pub fn advance(&mut self, seconds: f64) {
        if self.is_settled {
            return;
        }
        // A long pause (the window hidden, a breakpoint) isn't caught up on.
        self.owed = (self.owed + seconds.max(0.0)).min(Self::TIMESTEP * 6.0);
        while self.owed >= Self::TIMESTEP && !self.is_settled {
            self.owed -= Self::TIMESTEP;
            self.step();
        }
    }

    fn step(&mut self) {
        let (start, end) = Self::hanging_points(self.anchors.0, self.anchors.1);
        let last = self.chain.len() - 1;
        self.rest_length += (Self::length(start, end) - self.rest_length) * Self::GROWTH;
        let rest = self.rest_length / last as f64;
        let fall = Self::GRAVITY * Self::TIMESTEP * Self::TIMESTEP;
        let before = self.chain.clone();
        for index in 1..last {
            let (point, old) = (self.chain[index], self.previous[index]);
            self.previous[index] = point;
            self.chain[index] = Point::new(point.x + (point.x - old.x) * Self::DAMPING, point.y + (point.y - old.y) * Self::DAMPING + fall);
        }
        self.chain[0] = start;
        self.chain[last] = end;
        self.previous[0] = start;
        self.previous[last] = end;
        for _ in 0..Self::ITERATIONS {
            for index in 0..last {
                let (p, q) = (self.chain[index], self.chain[index + 1]);
                let (dx, dy) = (q.x - p.x, q.y - p.y);
                let distance = dx.hypot(dy);
                if distance <= 0.0001 {
                    continue;
                }
                let error = (distance - rest) / distance;
                // The hanging points don't move: the free particle takes the whole correction.
                let share = if index == 0 {
                    (0.0, 1.0)
                } else if index + 1 == last {
                    (1.0, 0.0)
                } else {
                    (0.5, 0.5)
                };
                self.chain[index] = Point::new(p.x + dx * error * share.0, p.y + dy * error * share.0);
                self.chain[index + 1] = Point::new(q.x - dx * error * share.1, q.y - dy * error * share.1);
            }
        }
        let moved = self.chain.iter().zip(&before).map(|(now, then)| distance(*then, *now)).fold(0.0, f64::max);
        self.calm = if moved < Self::STILLNESS { self.calm + 1 } else { 0 };
        if self.calm >= 30 {
            self.previous = self.chain.clone();
            self.is_settled = true;
        }
    }

    /// The first chain particle at least `distance` along the chain from `end`.
    fn join(&self, end: usize, step: isize, after: f64) -> usize {
        let (mut index, mut travelled) = (end, 0.0);
        while let Some(next) = index.checked_add_signed(step).filter(|next| *next < self.chain.len() && travelled < after) {
            travelled += distance(self.chain[index], self.chain[next]);
            index = next;
        }
        index
    }

    /// The stretch from an anchor into chain particle `join`: straight out of the card, then
    /// bending to meet the chain along it.
    fn plug(&self, anchor: RopeAnchor, join: usize, step: isize) -> Vec<Point> {
        let target = self.chain[join];
        let gap = distance(anchor.point, target);
        let ahead = self.chain[join.saturating_add_signed(step).min(self.chain.len() - 1)];
        let behind = self.chain[join.wrapping_add_signed(-step)];
        let size = (ahead.x - behind.x).hypot(ahead.y - behind.y);
        let tangent = if size > 0.0 { Vector::new((ahead.x - behind.x) / size, (ahead.y - behind.y) / size) } else { Vector::ZERO };
        let c1 = Point::new(anchor.point.x + anchor.direction.dx * gap * 0.5, anchor.point.y + anchor.direction.dy * gap * 0.5);
        let c2 = Point::new(target.x - tangent.dx * gap * 0.3, target.y - tangent.dy * gap * 0.3);
        let samples = 10;
        (0..=samples).map(|index| bezier(anchor.point, c1, c2, target, index as f64 / samples as f64)).collect()
    }

    /// How far out of each card the line runs before the chain hangs: less when the cards are close.
    fn lead(a: RopeAnchor, b: RopeAnchor) -> f64 {
        Self::MAXIMUM_LEAD.min(distance(a.point, b.point) * 0.12 + 4.0)
    }

    /// The points the chain hangs from, a lead out of each card.
    fn hanging_points(a: RopeAnchor, b: RopeAnchor) -> (Point, Point) {
        let lead = Self::lead(a, b);
        (
            Point::new(a.point.x + a.direction.dx * lead, a.point.y + a.direction.dy * lead),
            Point::new(b.point.x + b.direction.dx * lead, b.point.y + b.direction.dy * lead),
        )
    }

    /// The chain's natural length between its hanging points: across, plus slack.
    fn length(start: Point, end: Point) -> f64 {
        distance(start, end) * (1.0 + Self::SLACK) + 16.0
    }
}

fn bezier(p0: Point, p1: Point, p2: Point, p3: Point, t: f64) -> Point {
    let u = 1.0 - t;
    Point::new(
        u * u * u * p0.x + 3.0 * u * u * t * p1.x + 3.0 * u * t * t * p2.x + t * t * t * p3.x,
        u * u * u * p0.y + 3.0 * u * u * t * p1.y + 3.0 * u * t * t * p2.y + t * t * t * p3.y,
    )
}

fn close(x: RopeAnchor, y: RopeAnchor) -> bool {
    (x.point.x - y.point.x).abs() < 0.01 && (x.point.y - y.point.y).abs() < 0.01 && x.direction == y.direction
}
