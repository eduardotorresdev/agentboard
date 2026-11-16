use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::{Connection, Point, Rect, Size, Uuid};

/// A card as the layouts see it (Swift's `BoardLayout.Item`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LayoutItem {
    pub id: Uuid,
    pub frame: Rect,
    /// An agent: what a group prefers to grow from.
    pub is_hub: bool,
}

/// How a canvas arranges its cards, and so where a new one goes.
///
/// Cards joined by lines form a group. A group grows as a tree to the right of its hub (the agent
/// with the most lines): each card's peers stack in the column right of it, top-aligned with
/// it. Groups, and the cards on their own, are then packed in reading order into rows about as
/// wide as the screen, each taking the first free spot from the top-left.
///
/// A new card follows the same rules: one an agent adds, connected to it, goes in the column
/// right of that agent, below the cards already there; any other takes the first free spot in
/// the rows, as a group of its own would.
pub struct BoardLayout;

struct Arranged {
    /// Relative to the group's top-left corner.
    frames: HashMap<Uuid, Rect>,
    size: Size,
    /// Where the group sits now.
    original: Rect,
}

impl BoardLayout {
    /// Between a card and the column of its peers.
    pub const COLUMN_GAP: f64 = 64.0;
    /// Between cards stacked in a column.
    pub const ROW_GAP: f64 = 32.0;
    /// Between groups.
    pub const GROUP_GAP: f64 = 96.0;
    /// The width over height the rows aim for when no screen says otherwise.
    pub const DEFAULT_ASPECT: f64 = 16.0 / 10.0;

    // Organizing

    /// Where every card goes, starting from the top-left corner the cards occupy now. Cards
    /// keep their size; only the origin changes.
    pub fn organize(items: &[LayoutItem], connections: &[Connection], aspect: f64) -> HashMap<Uuid, Rect> {
        let Some(bounds) = union(items.iter().map(|item| item.frame)) else { return HashMap::new() };
        let mut groups: Vec<Arranged> = Self::groups(items, connections).iter().map(|group| arrange(group, connections)).collect();
        // Reading order of where the groups are now, so the result still looks familiar.
        groups.sort_by(|a, b| reading_order(&a.original, &b.original));
        let sizes: Vec<Size> = groups.iter().map(|group| group.size).collect();
        let width = row_width(&sizes, aspect);
        let mut placed: Vec<Rect> = Vec::new();
        let mut result = HashMap::new();
        for group in groups {
            let origin = first_fit(group.size, &placed, bounds.origin, width, Self::GROUP_GAP);
            placed.push(Rect::at(origin, group.size));
            for (id, frame) in group.frames {
                result.insert(id, frame.offset_by(origin.x, origin.y));
            }
        }
        result
    }

    // New cards

    /// Where a new card of `size` goes. Connected to `parent`: in the column right of it,
    /// below the cards in the way. Otherwise: the first free spot in the rows of groups.
    /// None when the canvas is empty (or `parent` isn't on it), for the caller to pick.
    pub fn slot(size: Size, parent: Option<Uuid>, items: &[LayoutItem], connections: &[Connection], aspect: f64) -> Option<Point> {
        let frames: Vec<Rect> = items.iter().map(|item| item.frame).collect();
        if let Some(parent) = parent {
            let frame = items.iter().find(|item| item.id == parent)?.frame;
            return Some(slot_right_of(size, frame, &frames));
        }
        let bounds = union(frames.iter().copied())?;
        let boxes: Vec<Rect> = Self::groups(items, connections).iter().filter_map(|group| union(group.iter().map(|item| item.frame))).collect();
        let sizes: Vec<Size> = boxes.iter().map(|group| group.size).chain([size]).collect();
        Some(first_fit(size, &boxes, bounds.origin, row_width(&sizes, aspect), Self::GROUP_GAP))
    }

    // Groups

    /// The cards joined by lines, each group in the order the items came.
    pub(crate) fn groups(items: &[LayoutItem], connections: &[Connection]) -> Vec<Vec<LayoutItem>> {
        let mut parent: HashMap<Uuid, Uuid> = items.iter().map(|item| (item.id, item.id)).collect();
        fn root(parent: &mut HashMap<Uuid, Uuid>, mut id: Uuid) -> Uuid {
            loop {
                let next = parent[&id];
                if next == id {
                    return id;
                }
                parent.insert(id, parent[&next]);
                id = next;
            }
        }
        for connection in connections {
            if parent.contains_key(&connection.a) && parent.contains_key(&connection.b) {
                let (a, b) = (root(&mut parent, connection.a), root(&mut parent, connection.b));
                if a != b {
                    parent.insert(a, b);
                }
            }
        }
        let mut order: Vec<Uuid> = Vec::new();
        let mut members: HashMap<Uuid, Vec<LayoutItem>> = HashMap::new();
        for item in items {
            let key = root(&mut parent, item.id);
            if !members.contains_key(&key) {
                order.push(key);
            }
            members.entry(key).or_default().push(*item);
        }
        order.iter().filter_map(|key| members.remove(key)).collect()
    }
}

/// The column right of `frame`, at its top or below whatever is in the way there.
fn slot_right_of(size: Size, frame: Rect, frames: &[Rect]) -> Point {
    let x = frame.max_x() + BoardLayout::COLUMN_GAP;
    let mut tops: Vec<f64> = frames.iter().map(|other| other.max_y() + BoardLayout::ROW_GAP).filter(|top| *top > frame.min_y()).collect();
    tops.push(frame.min_y());
    tops.sort_by(f64::total_cmp);
    for y in tops {
        let candidate = Rect::at(Point::new(x, y), size);
        if !frames.iter().any(|other| overlaps(other, &candidate, BoardLayout::ROW_GAP)) {
            return candidate.origin;
        }
    }
    // Unreachable: below the lowest card nothing is in the way.
    Point::new(x, frames.iter().map(Rect::max_y).fold(frame.min_y(), f64::max) + BoardLayout::ROW_GAP)
}

/// Lays a group out as a tree growing right from its hub.
fn arrange(group: &[LayoutItem], connections: &[Connection]) -> Arranged {
    let by_id: HashMap<Uuid, LayoutItem> = group.iter().map(|item| (item.id, *item)).collect();
    let mut peers: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
    for connection in connections {
        if by_id.contains_key(&connection.a) && by_id.contains_key(&connection.b) && connection.a != connection.b {
            peers.entry(connection.a).or_default().push(connection.b);
            peers.entry(connection.b).or_default().push(connection.a);
        }
    }
    let degree = |item: &LayoutItem| peers.get(&item.id).map_or(0, |list| list.iter().collect::<HashSet<_>>().len());
    let hub = group
        .iter()
        .min_by(|a, b| b.is_hub.cmp(&a.is_hub).then(degree(b).cmp(&degree(a))).then(reading_order(&a.frame, &b.frame)))
        .expect("a group has a card");

    // Breadth first, so each card hangs from the closest card to the hub it is joined to.
    let mut children: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
    let mut seen: HashSet<Uuid> = HashSet::from([hub.id]);
    let mut queue = vec![hub.id];
    while !queue.is_empty() {
        let id = queue.remove(0);
        let mut next: Vec<LayoutItem> = Vec::new();
        for peer in peers.get(&id).into_iter().flatten() {
            if seen.insert(*peer) {
                next.push(by_id[peer]);
            }
        }
        next.sort_by(|a, b| reading_order(&a.frame, &b.frame));
        let next: Vec<Uuid> = next.iter().map(|item| item.id).collect();
        queue.extend(&next);
        children.insert(id, next);
    }

    /// Places `id` at `origin` with its peers to the right; answers the height it all takes.
    fn place(id: Uuid, origin: Point, by_id: &HashMap<Uuid, LayoutItem>, children: &HashMap<Uuid, Vec<Uuid>>, frames: &mut HashMap<Uuid, Rect>) -> f64 {
        let size = by_id[&id].frame.size;
        frames.insert(id, Rect::at(origin, size));
        let below = children.get(&id).map_or(&[][..], Vec::as_slice);
        let mut y = origin.y;
        for child in below {
            y += place(*child, Point::new(origin.x + size.width + BoardLayout::COLUMN_GAP, y), by_id, children, frames) + BoardLayout::ROW_GAP;
        }
        let stacked = if below.is_empty() { 0.0 } else { y - BoardLayout::ROW_GAP - origin.y };
        size.height.max(stacked)
    }
    let mut frames = HashMap::new();
    place(hub.id, Point::ZERO, &by_id, &children, &mut frames);
    let bounds = union(frames.values().copied()).unwrap_or_default();
    Arranged { frames, size: bounds.size, original: union(group.iter().map(|item| item.frame)).unwrap_or_default() }
}

// Packing

/// About as wide as the screen's shape for this much area, and never narrower than the widest group.
fn row_width(sizes: &[Size], aspect: f64) -> f64 {
    let area: f64 = sizes.iter().map(|size| (size.width + BoardLayout::GROUP_GAP) * (size.height + BoardLayout::GROUP_GAP)).sum();
    sizes.iter().map(|size| size.width).fold(0.0, f64::max).max((area * aspect.max(0.1)).sqrt())
}

/// The first spot, top to bottom then left to right, where `size` fits within `width` of
/// `origin.x` without coming closer than `gap` to anything placed.
fn first_fit(size: Size, placed: &[Rect], origin: Point, width: f64, gap: f64) -> Point {
    let xs: Vec<f64> = [origin.x].into_iter().chain(placed.iter().map(|rect| rect.max_x() + gap)).collect();
    let ys: Vec<f64> = [origin.y].into_iter().chain(placed.iter().map(|rect| rect.max_y() + gap)).collect();
    let mut candidates: Vec<Point> = Vec::new();
    for y in ys.iter().filter(|y| **y >= origin.y) {
        for x in xs.iter().filter(|x| **x >= origin.x && (**x == origin.x || **x + size.width <= origin.x + width)) {
            candidates.push(Point::new(*x, *y));
        }
    }
    candidates.sort_by(|a, b| a.y.total_cmp(&b.y).then(a.x.total_cmp(&b.x)));
    for candidate in candidates {
        let rect = Rect::at(candidate, size);
        if !placed.iter().any(|other| overlaps(other, &rect, gap)) {
            return candidate;
        }
    }
    // Unreachable: below everything at the left edge is always free.
    Point::new(origin.x, placed.iter().map(Rect::max_y).fold(origin.y, f64::max) + gap)
}

fn overlaps(a: &Rect, b: &Rect, gap: f64) -> bool {
    // A hair under the gap, so cards exactly `gap` apart still fit.
    a.inset_by(-(gap - 0.5), -(gap - 0.5)).intersects(b)
}

fn reading_order(a: &Rect, b: &Rect) -> Ordering {
    a.min_y().total_cmp(&b.min_y()).then(a.min_x().total_cmp(&b.min_x()))
}

fn union(frames: impl IntoIterator<Item = Rect>) -> Option<Rect> {
    frames.into_iter().reduce(|all, frame| all.union(&frame))
}
