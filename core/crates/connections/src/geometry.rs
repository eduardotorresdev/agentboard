//! Board coordinates, as CoreGraphics has them (y grows downward).

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vector {
    pub dx: f64,
    pub dy: f64,
}

/// A rectangle of positive size.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub origin: Point,
    pub size: Size,
}

impl Point {
    pub const ZERO: Point = Point { x: 0.0, y: 0.0 };

    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

impl Vector {
    pub const ZERO: Vector = Vector { dx: 0.0, dy: 0.0 };

    pub const fn new(dx: f64, dy: f64) -> Self {
        Self { dx, dy }
    }
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { origin: Point::new(x, y), size: Size::new(width, height) }
    }

    pub const fn at(origin: Point, size: Size) -> Self {
        Self { origin, size }
    }

    pub fn width(&self) -> f64 { self.size.width }
    pub fn height(&self) -> f64 { self.size.height }
    pub fn min_x(&self) -> f64 { self.origin.x }
    pub fn min_y(&self) -> f64 { self.origin.y }
    pub fn max_x(&self) -> f64 { self.origin.x + self.size.width }
    pub fn max_y(&self) -> f64 { self.origin.y + self.size.height }
    pub fn mid_x(&self) -> f64 { self.origin.x + self.size.width / 2.0 }
    pub fn mid_y(&self) -> f64 { self.origin.y + self.size.height / 2.0 }

    pub fn union(&self, other: &Rect) -> Rect {
        let (x, y) = (self.min_x().min(other.min_x()), self.min_y().min(other.min_y()));
        Rect::new(x, y, self.max_x().max(other.max_x()) - x, self.max_y().max(other.max_y()) - y)
    }

    /// Whether they share any area: rectangles that only touch don't.
    pub fn intersects(&self, other: &Rect) -> bool {
        self.min_x() < other.max_x() && other.min_x() < self.max_x() && self.min_y() < other.max_y() && other.min_y() < self.max_y()
    }

    /// Shrunk by `dx` and `dy` on each side (grown, when negative).
    pub fn inset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.origin.x + dx, self.origin.y + dy, self.size.width - 2.0 * dx, self.size.height - 2.0 * dy)
    }

    pub fn offset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.origin.x + dx, self.origin.y + dy, self.size.width, self.size.height)
    }
}
