use connections::*;

fn item(x: f64, y: f64, width: f64, height: f64, hub: bool) -> LayoutItem {
    LayoutItem { id: Uuid::new(), frame: Rect::new(x, y, width, height), is_hub: hub }
}

fn no_overlaps(frames: &[Rect]) -> bool {
    frames.iter().enumerate().all(|(index, a)| frames[index + 1..].iter().all(|b| !a.intersects(b)))
}

const ASPECT: f64 = BoardLayout::DEFAULT_ASPECT;

#[test]
fn connected_cards_stack_in_the_column_right_of_their_agent() {
    let runner = item(-900.0, 700.0, 500.0, 260.0, false);
    let agent = item(300.0, 300.0, 640.0, 420.0, true);
    let note = item(2000.0, -50.0, 280.0, 240.0, false);
    let lines = [Connection::new(runner.id, agent.id), Connection::new(agent.id, note.id)];

    let result = BoardLayout::organize(&[runner, agent, note], &lines, ASPECT);

    let (a, r, n) = (result[&agent.id], result[&runner.id], result[&note.id]);
    // The agent is the root, whichever card came first or sat furthest up.
    assert_eq!(r.min_x(), a.max_x() + BoardLayout::COLUMN_GAP);
    assert_eq!(n.min_x(), a.max_x() + BoardLayout::COLUMN_GAP);
    // Its peers stack top-aligned with it, in the order they sat (the note was higher).
    assert_eq!(n.min_y(), a.min_y());
    assert_eq!(r.min_y(), n.max_y() + BoardLayout::ROW_GAP);
    // Sizes stay.
    assert_eq!(r.size, runner.frame.size);
}

#[test]
fn groups_pack_from_the_cards_top_left_corner_without_overlapping() {
    let mut items = Vec::new();
    let mut lines = Vec::new();
    for index in 0..5 {
        let index = index as f64;
        let agent = item(index * 37.0, index * 53.0, 640.0, 420.0, true);
        let runner = item(index * 41.0, index * 29.0, 500.0, 260.0, false);
        items.extend([agent, runner]);
        lines.push(Connection::new(agent.id, runner.id));
    }
    items.extend((0..4).map(|index| item(index as f64 * 11.0, index as f64 * 17.0, 280.0, 240.0, false)));

    let result = BoardLayout::organize(&items, &lines, 16.0 / 10.0);

    assert_eq!(result.len(), items.len());
    let frames: Vec<Rect> = result.values().copied().collect();
    assert!(no_overlaps(&frames));
    let union = frames.iter().fold(frames[0], |all, frame| all.union(frame));
    assert_eq!(union.origin, Point::new(0.0, 0.0));
    // Rows, not one long line: about the shape of the screen.
    assert!(union.width() / union.height() < 4.0);
}

#[test]
fn organizing_twice_changes_nothing() {
    let agent = item(0.0, 0.0, 640.0, 420.0, true);
    let runner = item(900.0, 900.0, 500.0, 260.0, false);
    let lone = item(-400.0, 2000.0, 280.0, 240.0, false);
    let items = [agent, runner, lone];
    let lines = [Connection::new(agent.id, runner.id)];
    let first = BoardLayout::organize(&items, &lines, ASPECT);
    let moved: Vec<LayoutItem> = items.iter().map(|item| LayoutItem { frame: first[&item.id], ..*item }).collect();
    assert_eq!(BoardLayout::organize(&moved, &lines, ASPECT), first);
}

#[test]
fn a_card_an_agent_adds_goes_below_its_peers_in_the_column_right_of_it() {
    let agent = item(0.0, 0.0, 640.0, 420.0, true);
    let runner = item(640.0 + BoardLayout::COLUMN_GAP, 0.0, 500.0, 260.0, false);
    let lines = [Connection::new(agent.id, runner.id)];

    let slot = BoardLayout::slot(Size::new(280.0, 240.0), Some(agent.id), &[agent, runner], &lines, ASPECT);

    assert_eq!(slot, Some(Point::new(runner.frame.min_x(), runner.frame.max_y() + BoardLayout::ROW_GAP)));
    assert_eq!(BoardLayout::slot(Size::new(280.0, 240.0), Some(Uuid::new()), &[agent, runner], &lines, ASPECT), None);
}

#[test]
fn a_card_the_user_adds_takes_the_next_free_spot_in_the_rows() {
    let agent = item(0.0, 0.0, 640.0, 420.0, true);
    let runner = item(640.0 + BoardLayout::COLUMN_GAP, 0.0, 500.0, 260.0, false);
    let items = [agent, runner];
    let lines = [Connection::new(agent.id, runner.id)];
    let size = Size::new(280.0, 240.0);

    let slot = BoardLayout::slot(size, None, &items, &lines, 16.0 / 10.0).unwrap();

    // Where organizing would put a group of its own: below this wide one keeps the rows
    // about the screen's shape, beside it would make one long strip.
    assert_eq!(slot, Point::new(0.0, agent.frame.max_y() + BoardLayout::GROUP_GAP));
    assert!(no_overlaps(&[agent.frame, runner.frame, Rect::at(slot, size)]));
}

#[test]
fn a_card_the_user_adds_fills_the_room_beside_a_tall_group() {
    let agent = item(0.0, 0.0, 640.0, 420.0, true);
    let runners: Vec<LayoutItem> = (0..4).map(|index| item(704.0, index as f64 * 292.0, 500.0, 260.0, false)).collect();
    let lines: Vec<Connection> = runners.iter().map(|runner| Connection::new(agent.id, runner.id)).collect();
    let items: Vec<LayoutItem> = [agent].into_iter().chain(runners).collect();

    let slot = BoardLayout::slot(Size::new(280.0, 240.0), None, &items, &lines, 16.0 / 10.0).unwrap();

    assert_eq!(slot, Point::new(1204.0 + BoardLayout::GROUP_GAP, 0.0));
}

#[test]
fn an_empty_canvas_leaves_the_spot_to_the_caller() {
    assert_eq!(BoardLayout::slot(Size::new(100.0, 100.0), None, &[], &[], ASPECT), None);
    assert!(BoardLayout::organize(&[], &[], ASPECT).is_empty());
}
