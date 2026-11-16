use std::collections::HashMap;

use connections::*;

fn item(x: f64, y: f64, width: f64, height: f64, hub: bool) -> LayoutItem {
    LayoutItem { id: Uuid::new(), frame: Rect::new(x, y, width, height), is_hub: hub }
}

fn no_overlaps(frames: &[Rect]) -> bool {
    frames.iter().enumerate().all(|(index, a)| frames[index + 1..].iter().all(|b| !a.intersects(b)))
}

/// Agents with runners, notes and images, a couple linked to each other, and loners.
fn board(agents: usize) -> (Vec<LayoutItem>, Vec<Connection>) {
    let (mut items, mut lines) = (Vec::new(), Vec::new());
    let mut previous: Option<Uuid> = None;
    for index in 0..agents {
        let agent = item(index as f64 * 13.0, 0.0, 640.0, 420.0, true);
        let runner = item(0.0, index as f64 * 7.0, 500.0, 260.0, false);
        let note = item(5.0, 5.0, 280.0, 240.0, false);
        items.extend([agent, runner, note]);
        lines.extend([Connection::new(agent.id, runner.id), Connection::new(note.id, agent.id)]);
        if let (1, Some(previous)) = (index % 2, previous) {
            lines.push(Connection::new(previous, agent.id));
        }
        previous = Some(agent.id);
    }
    items.extend((0..3).map(|_| item(0.0, 0.0, 900.0, 600.0, false)));
    (items, lines)
}

#[test]
fn one_card_stays_put() {
    let lone = item(120.0, -40.0, 400.0, 300.0, false);
    assert_eq!(RadialLayout::organize(&[lone], &[]), HashMap::from([(lone.id, lone.frame)]));
}

#[test]
fn many_cards_never_overlap_and_keep_their_size() {
    let (items, lines) = board(12);
    let result = RadialLayout::organize(&items, &lines);
    assert_eq!(result.len(), items.len());
    assert!(no_overlaps(&result.values().copied().collect::<Vec<_>>()));
    for item in &items {
        assert_eq!(result[&item.id].size, item.frame.size);
    }
}

#[test]
fn no_card_covers_an_agents_composer() {
    let (items, lines) = board(8);
    let result = RadialLayout::organize(&items, &lines);
    let footprints: Vec<Rect> = items
        .iter()
        .map(|item| {
            let mut frame = result[&item.id];
            if item.is_hub {
                frame.size.height += RadialLayout::COMPOSER_ROOM;
            }
            frame
        })
        .collect();
    assert!(no_overlaps(&footprints));
}

#[test]
fn satellites_sit_next_to_their_agent() {
    let (items, lines) = board(6);
    let result = RadialLayout::organize(&items, &lines);
    let (agent, runner, far) = (result[&items[3].id], result[&items[4].id], result[&items[9].id]);
    let distance = |a: Rect, b: Rect| (a.mid_x() - b.mid_x()).hypot(a.mid_y() - b.mid_y());
    assert!(distance(agent, runner) < distance(agent, far));
}

#[test]
fn organizing_twice_changes_nothing() {
    let (items, lines) = board(5);
    let first = RadialLayout::organize(&items, &lines);
    let moved: Vec<LayoutItem> = items.iter().map(|item| LayoutItem { frame: first[&item.id], ..*item }).collect();
    assert_eq!(RadialLayout::organize(&moved, &lines), first);
}

#[test]
fn a_new_loner_leaves_the_connected_cards_where_they_were() {
    let (mut items, lines) = board(4);
    let before = RadialLayout::organize(&items, &lines);
    items.push(item(0.0, 0.0, 280.0, 240.0, false));
    let after = RadialLayout::organize(&items, &lines);
    // The 12 connected cards keep their spots; only the loners' ring makes room.
    for item in &items[..12] {
        assert_eq!(after[&item.id], before[&item.id]);
    }
}
