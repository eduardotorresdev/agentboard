use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;

use crate::{Connection, LayoutItem, Point, Rect, Size, Uuid};

/// Organizes a canvas radially around its most connected agent.
///
/// Each agent (hub) forms a cluster with the non-agent cards joined to it (runners, post-its,
/// images, browsers), placed on a ring around it. The busiest cluster sits in the center; the
/// others go on concentric rings around it, connected clusters next to each other (breadth
/// first along agent-to-agent lines), unconnected cards last, on the outer rings.
///
/// Positions depend only on the input order (creation order), the sizes and the lines, never
/// on where cards sit now, so organizing twice changes nothing and a new card (last in the
/// order) lands at the end of the outer ring. The center card keeps its position.
pub struct RadialLayout;

impl RadialLayout {
    /// The least room between two cards.
    pub const GAP: f64 = 48.0;
    /// Below an agent card: room for its composer (8 pt gap, 34 pt tall), shown when focused or drafting.
    pub const COMPOSER_ROOM: f64 = 42.0;

    /// The room a card takes: an agent's includes its composer below it.
    fn footprint(item: &LayoutItem) -> Size {
        Size::new(item.frame.width(), item.frame.height() + if item.is_hub { Self::COMPOSER_ROOM } else { 0.0 })
    }

    pub fn organize(items: &[LayoutItem], connections: &[Connection]) -> HashMap<Uuid, Rect> {
        if items.is_empty() {
            return HashMap::new();
        }
        let mut order: HashMap<Uuid, usize> = HashMap::new();
        let mut by_id: HashMap<Uuid, LayoutItem> = HashMap::new();
        for (index, item) in items.iter().enumerate() {
            order.entry(item.id).or_insert(index);
            by_id.entry(item.id).or_insert(*item);
        }
        let mut peers: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
        for c in connections {
            if c.a != c.b && by_id.contains_key(&c.a) && by_id.contains_key(&c.b) {
                peers.entry(c.a).or_default().push(c.b);
                peers.entry(c.b).or_default().push(c.a);
            }
        }
        // Each id once, in the input order.
        let sorted = |ids: &mut dyn Iterator<Item = Uuid>| -> Vec<Uuid> {
            let mut ids: Vec<Uuid> = ids.collect();
            ids.sort_by_key(|id| order[id]);
            ids.dedup();
            ids
        };
        let peers_of = |id: Uuid| sorted(&mut peers.get(&id).into_iter().flatten().copied());
        let degree = |id: Uuid| peers_of(id).len();
        let busiest_first = |ids: &mut Vec<Uuid>| ids.sort_by_key(|id| (std::cmp::Reverse(degree(*id)), order[id]));

        // Clusters: every hub, then hub-less cards around their most connected one.
        let mut owner: HashMap<Uuid, Uuid> = HashMap::new();
        let mut hubs: Vec<Uuid> = items.iter().filter(|item| item.is_hub).map(|item| item.id).collect();
        for hub in &hubs {
            owner.insert(*hub, *hub);
        }
        busiest_first(&mut hubs);
        for hub in hubs {
            for peer in peers_of(hub) {
                owner.entry(peer).or_insert(hub);
            }
        }
        let mut rest: Vec<Uuid> = items.iter().map(|item| item.id).filter(|id| !owner.contains_key(id)).collect();
        busiest_first(&mut rest);
        for id in rest {
            if owner.contains_key(&id) {
                continue;
            }
            owner.insert(id, id);
            // Its unowned component hangs from it.
            let mut queue = vec![id];
            while !queue.is_empty() {
                for peer in peers_of(queue.remove(0)) {
                    if let Entry::Vacant(unowned) = owner.entry(peer) {
                        unowned.insert(id);
                        queue.push(peer);
                    }
                }
            }
        }
        let mut members: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
        for item in items {
            if owner[&item.id] != item.id {
                members.entry(owner[&item.id]).or_default().push(item.id);
            }
        }

        // Each cluster as a disc: its center card in the middle, its cards on a ring around it.
        let radius = |id: &Uuid| {
            let size = Self::footprint(&by_id[id]);
            (size.width * size.width + size.height * size.height).sqrt() / 2.0 + Self::GAP / 2.0
        };
        let clusters = sorted(&mut owner.values().copied());
        let mut offsets: HashMap<Uuid, Point> = HashMap::new(); // Card centers relative to their cluster's center.
        let mut discs: HashMap<Uuid, f64> = HashMap::new();
        for center in &clusters {
            offsets.insert(*center, Point::ZERO);
            let Some(satellites) = members.get(center) else {
                discs.insert(*center, radius(center));
                continue;
            };
            let radii: Vec<f64> = satellites.iter().map(radius).collect();
            let (ring, angles) = ring_fit(&radii, radius(center));
            let mut angle = -PI / 2.0;
            for (index, id) in satellites.iter().enumerate() {
                angle += angles[index] / 2.0;
                offsets.insert(*id, Point::new(angle.cos() * ring, angle.sin() * ring));
                angle += angles[index] / 2.0;
            }
            discs.insert(*center, ring + maximum(&radii));
        }

        // Cluster graph, then the ring order: center's component breadth first, other components, then loners.
        let mut links: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
        for (id, list) in &peers {
            for peer in list {
                if owner[id] != owner[peer] {
                    links.entry(owner[id]).or_default().push(owner[peer]);
                }
            }
        }
        let weight = |c: &Uuid| degree(*c) + members.get(c).map_or(0, Vec::len);
        let core = *clusters.iter().min_by_key(|c| (std::cmp::Reverse(weight(c)), order[*c])).expect("a board with cards has a cluster");
        let mut ring_order: Vec<Uuid> = Vec::new();
        let mut seen: HashSet<Uuid> = HashSet::from([core]);
        let mut loners: Vec<Uuid> = Vec::new();
        for start in [core].iter().chain(&clusters) {
            if *start != core && seen.contains(start) {
                continue;
            }
            if *start != core && !links.contains_key(start) && !members.contains_key(start) {
                loners.push(*start);
                continue;
            }
            seen.insert(*start);
            let mut queue = vec![*start];
            if *start != core {
                ring_order.push(*start);
            }
            while !queue.is_empty() {
                for next in sorted(&mut links.get(&queue.remove(0)).into_iter().flatten().copied()) {
                    if seen.insert(next) {
                        ring_order.push(next);
                        queue.push(next);
                    }
                }
            }
        }
        let first_loner = ring_order.len();
        ring_order.extend(loners);

        // Concentric rings, each as small as its discs allow, filled in order.
        let mut cluster_centers: HashMap<Uuid, Point> = HashMap::from([(core, Point::ZERO)]);
        let mut inner = discs[&core];
        let mut index = 0;
        let discs_of = |ids: &[Uuid]| -> Vec<f64> { ids.iter().map(|id| discs[id]).collect() };
        while index < ring_order.len() {
            let mut count = 1;
            // Loners start a ring of their own, so adding one never moves a connected card.
            while index + count < ring_order.len()
                && index + count != first_loner
                && ring_fit_within(&discs_of(&ring_order[index..=index + count]), inner, false).is_some()
            {
                count += 1;
            }
            let ring_discs = discs_of(&ring_order[index..index + count]);
            let (ring, angles) = ring_fit(&ring_discs, inner);
            let mut angle = -PI / 2.0;
            for (offset, id) in ring_order[index..index + count].iter().enumerate() {
                angle += angles[offset] / 2.0;
                cluster_centers.insert(*id, Point::new(angle.cos() * ring, angle.sin() * ring));
                angle += angles[offset] / 2.0;
            }
            inner = ring + maximum(&ring_discs);
            index += count;
        }

        // Anchored on the center card's current center.
        let center = &by_id[&core];
        let anchor = Point::new(center.frame.mid_x(), center.frame.min_y() + Self::footprint(center).height / 2.0);
        let mut result = HashMap::new();
        for item in items {
            let (cluster, offset) = (cluster_centers[&owner[&item.id]], offsets[&item.id]);
            let size = Self::footprint(item);
            let x = (anchor.x + cluster.x + offset.x - size.width / 2.0).round();
            let y = (anchor.y + cluster.y + offset.y - size.height / 2.0).round();
            result.insert(item.id, Rect::at(Point::new(x, y), item.frame.size));
        }
        result
    }
}

fn maximum(values: &[f64]) -> f64 {
    values.iter().copied().fold(f64::NEG_INFINITY, f64::max)
}

/// The radius of a ring around a disc of `inner` that holds discs of `radii` without touching,
/// and the angle each one gets, spread evenly. With `grow: false`, none when they need a
/// radius beyond the smallest one (the ring would have to grow to take them).
fn ring_fit_within(radii: &[f64], inner: f64, grow: bool) -> Option<(f64, Vec<f64>)> {
    let mut ring = inner + maximum(radii);
    let angles = |ring: f64| -> Vec<f64> { radii.iter().map(|r| 2.0 * (r / ring).min(1.0).asin()).collect() };
    while radii.len() > 1 && angles(ring).iter().sum::<f64>() > 2.0 * PI {
        if !grow {
            return None;
        }
        ring *= 1.05;
    }
    if radii.len() <= 1 {
        return Some((ring, vec![2.0 * PI]));
    }
    let used = angles(ring);
    let spare = (2.0 * PI - used.iter().sum::<f64>()) / radii.len() as f64;
    Some((ring, used.iter().map(|angle| angle + spare).collect()))
}

fn ring_fit(radii: &[f64], inner: f64) -> (f64, Vec<f64>) {
    ring_fit_within(radii, inner, true).expect("a ring that may grow fits")
}
