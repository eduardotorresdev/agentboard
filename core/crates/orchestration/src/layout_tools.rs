use serde_json::{json, Map, Value};

use connections::{find_element, find_element_by, Element, Point, Rect, Reply, Size, ToolDefinition, ToolProvider, ToolResult, Uuid};

use crate::image_card::ImageRecord;
use crate::image_group::{Direction, ImageGroup};
use crate::orchestrator::{is_inline_space, Turn};

/// `element_layout`, `element_move` and the `group_` tools: an agent sees where everything on
/// its board sits and how big it is, moves and resizes it, and keeps images and videos in
/// organizational groups (see `ImageGroup`).
pub(crate) struct LayoutTools;

const NO_GROUP: &str = "No such group on your board; element_layout lists them.";

/// The element of the caller's board that `address` names, or why there isn't exactly one.
fn element(turn: &Turn, address: Option<&Value>, caller: Uuid) -> Result<Element, String> {
    let on_board = turn.bus.elements_on_board_of(caller, &turn.board);
    let address = address.and_then(Value::as_str).unwrap_or("").trim_matches(is_inline_space);
    let Some(found) = find_element(address, &on_board) else {
        return Err(format!("Nothing named “{address}” is on your board; list_peers shows what is."));
    };
    let twins = on_board.iter().filter(|element| element.name.to_lowercase() == found.name.to_lowercase()).count();
    if twins > 1 && !address.to_uppercase().contains(&found.id.to_string().to_uppercase()) {
        return Err(format!("{twins} elements are named “{}”; give the id of the one you mean.", found.name));
    }
    Ok(found.clone())
}

/// The pictures `arguments["elements"]` names, or why not.
fn pictures(turn: &Turn, arguments: &Map<String, Value>, caller: Uuid) -> Result<Vec<Uuid>, String> {
    let mut ids = Vec::new();
    for address in arguments.get("elements").and_then(Value::as_array).into_iter().flatten() {
        let found = element(turn, Some(address), caller)?;
        if turn.image(found.id).is_none() {
            return Err(format!("“{}” is a {}; groups only take images and videos.", found.name, found.kind.0));
        }
        if !ids.contains(&found.id) {
            ids.push(found.id);
        }
    }
    if ids.is_empty() {
        return Err("Give `elements`: the images and videos to group, by name or id.".to_string());
    }
    Ok(ids)
}

fn group(turn: &Turn, arguments: &Map<String, Value>, caller: Uuid) -> Option<ImageGroup> {
    let groups = turn.image_groups_on_board_of(caller);
    find_element_by(arguments.get("group").and_then(Value::as_str).unwrap_or(""), &groups, |group| group.id, |group| &group.name).cloned()
}

fn place(frame: Rect) -> String {
    format!("x {}, y {}, width {}, height {}", frame.min_x() as i64, frame.min_y() as i64, frame.width() as i64, frame.height() as i64)
}

fn word(direction: Direction) -> &'static str {
    if direction == Direction::Vertical { "vertical" } else { "horizontal" }
}

fn listing(turn: &Turn, caller: Uuid) -> String {
    let mut lines: Vec<String> = turn
        .bus
        .elements_on_board_of(caller, &turn.board)
        .iter()
        .filter_map(|element| {
            let group = turn.image_group_of(element.id).map(|group| format!(", in group “{}”", group.name)).unwrap_or_default();
            Some(format!("- “{}” ({}, id: {}): {}{group}", element.name, element.kind.0, element.id, place(turn.frame_of(element.id)?)))
        })
        .collect();
    if lines.is_empty() {
        lines.push("Nothing on your board has a place yet.".to_string());
    }
    lines.insert(0, "Elements (board points; x grows right, y grows down):".to_string());
    let groups = turn.image_groups_on_board_of(caller);
    if !groups.is_empty() {
        lines.push("Groups:".to_string());
    }
    for group in groups {
        let members: Vec<&ImageRecord> = group.members.iter().filter_map(|member| turn.image(*member)).collect();
        let panel = members.iter().map(|member| member.frame).reduce(|all, frame| all.union(&frame)).unwrap_or_default().inset_by(-ImageGroup::PADDING, -ImageGroup::PADDING);
        let names = members.iter().map(|member| format!("“{}”", member.name)).collect::<Vec<_>>().join(", ");
        lines.push(format!("- “{}” (id: {}, {}, {}): {}; members in order: {names}", group.name, group.id, word(group.direction), group.color, place(panel)));
    }
    lines.join("\n")
}

fn move_element(turn: &mut Turn, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
    let found = match element(turn, arguments.get("element"), caller) {
        Ok(found) => found,
        Err(refusal) => return reply.send(ToolResult::error(refusal)),
    };
    let Some(mut frame) = turn.frame_of(found.id) else { return reply.send(ToolResult::error(format!("“{}” has no place of its own on the board.", found.name))) };
    let mut numbers = [None; 4];
    for (slot, key) in numbers.iter_mut().zip(["x", "y", "width", "height"]) {
        let Some(value) = arguments.get(key) else { continue };
        match value.as_f64().filter(|number| number.is_finite() && number.abs() <= 1_000_000.0) {
            Some(number) => *slot = Some(number.round()),
            None => return reply.send(ToolResult::error(format!("`{key}` is a number of board points."))),
        }
    }
    let [x, y, width, height] = numbers;
    if numbers.iter().all(Option::is_none) {
        return reply.send(ToolResult::error("Give `x` and `y` to move it, `width` and `height` to resize it."));
    }
    frame.origin = Point::new(x.unwrap_or(frame.min_x()), y.unwrap_or(frame.min_y()));
    // The smallest any card gets, as on the board.
    let sized = Rect::at(frame.origin, Size::new(width.unwrap_or(frame.width()).max(160.0), height.unwrap_or(frame.height()).max(120.0)));
    let mut note = "";
    let id = found.id;
    let done = |frame: Rect, note: &str| ToolResult::text(format!("“{}” is at x {}, y {}, {}×{} points.{note}", found.name, frame.min_x() as i64, frame.min_y() as i64, frame.width() as i64, frame.height() as i64));
    if let Some(record) = turn.image(id).cloned() {
        if let Some(width) = width {
            frame.size = ImageRecord::card_size_wide(width.min(ImageRecord::MAXIMUM_WIDTH), record.pixel_size);
        } else if height.is_some() {
            note = " Its size follows `width`; give that to resize it.";
        }
        turn.update_image(id, None, |image| image.frame = frame);
        turn.image_frame_changed(id, record.frame);
    } else if turn.record(id).is_some() {
        turn.update(id, None, |card| card.frame = sized);
    } else if turn.post_it(id).is_some() {
        turn.update_post_it(id, None, |note| note.frame = sized);
    } else if turn.file_tree(id).is_some() {
        turn.update_file_tree(id, None, |tree| tree.frame = sized);
    } else {
        // shortcut: browsers and simulators size themselves (device), so they only move; add resizing if agents need it.
        if width.is_some() || height.is_some() {
            note = " It only moves: its size is its own.";
        }
        let moved = done(frame, note);
        let arguments = json!({"id": id.to_string(), "x": frame.min_x(), "y": frame.min_y()});
        return turn.relay("board_move", arguments.as_object().unwrap_or(&Map::new()), caller, Reply::new(move |result| reply.send(if result.is_error { result } else { moved })));
    }
    reply.send(done(turn.frame_of(id).unwrap_or(frame), note))
}

impl<'a> ToolProvider<Turn<'a>> for LayoutTools {
    fn instructions(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Option<String> {
        Some(
            "element_layout lists every element of your board with its place and size (board points; x grows right, y grows \
             down) and the organizational groups. element_move moves an element, resizes it, or both. Groups keep images and \
             videos, nothing else, in one column (vertical) or one row (horizontal), snapped to the group's grid on a light \
             panel of a palette color: group_create makes one, group_edit changes its direction, color or members, \
             group_remove dissolves it and leaves its pictures in place. Moving or resizing a grouped picture moves or \
             resizes its whole group."
                .to_string(),
        )
    }

    fn tools(&self, _turn: &mut Turn<'a>, _caller: Uuid) -> Vec<ToolDefinition> {
        let tool = ToolDefinition::with_schema;
        let direction = json!({"type": "string", "enum": ["vertical", "horizontal"], "description": "vertical: one column, every card the same width. horizontal: one row, every picture the same height."});
        let color = json!({"type": "string", "enum": ImageGroup::COLORS, "description": "The light color of the group's panel."});
        let members = json!({"type": "array", "items": {"type": "string"}, "description": "The images and videos, by name or id, in the order they are laid out."});
        let group = json!({"type": "string", "description": "The group's name or id, as element_layout shows it."});
        vec![
            ToolDefinition::new(
                "element_layout",
                "Lists every element of your board with its top left corner (x, y), width and height in board points (x grows right, y grows down), and the organizational groups with their members.",
            ),
            tool(
                "element_move",
                "Moves an element of your board, resizes it, or both; what you leave out stays as it is. An image or video \
                 keeps its proportion: give `width` and its height follows. A browser, simulator or event source only moves. \
                 A grouped image or video takes its whole group along.",
                json!({"type": "object", "properties": {
                    "element": {"type": "string", "description": "The element's name or id, as list_peers shows it. Use the id when two share a name."},
                    "x": {"type": "number", "description": "The new left edge, in board points."},
                    "y": {"type": "number", "description": "The new top edge, in board points."},
                    "width": {"type": "number", "description": "The new width, in board points."},
                    "height": {"type": "number", "description": "The new height, in board points."},
                }, "required": ["element"]}),
            ),
            tool(
                "group_create",
                "Groups images and videos of your board in one column or one row, snapped to the group's grid, on a light panel. One already in another group moves to this one.",
                json!({"type": "object", "properties": {"elements": members, "direction": direction, "color": color}, "required": ["elements", "direction"]}),
            ),
            tool(
                "group_edit",
                "Changes a group: its direction, its color, or its members (`elements` replaces the whole list, in layout order). What you leave out stays.",
                json!({"type": "object", "properties": {"group": group, "elements": members, "direction": direction, "color": color}, "required": ["group"]}),
            ),
            tool("group_remove", "Dissolves a group. Its images and videos stay on the board, where they are.", json!({"type": "object", "properties": {"group": group}, "required": ["group"]})),
        ]
    }

    fn call(&mut self, turn: &mut Turn<'a>, name: &str, arguments: &Map<String, Value>, caller: Uuid, reply: Reply) {
        let direction = match arguments.get("direction").map(|direction| direction.as_str()) {
            None => None,
            Some(Some("vertical")) => Some(Direction::Vertical),
            Some(Some("horizontal")) => Some(Direction::Horizontal),
            Some(_) => return reply.send(ToolResult::error("`direction` is vertical or horizontal.")),
        };
        let color = arguments.get("color").and_then(Value::as_str);
        if color.is_some_and(|color| !ImageGroup::COLORS.contains(&color)) {
            return reply.send(ToolResult::error(format!("`color` is one of: {}.", ImageGroup::COLORS.join(", "))));
        }
        let result = match name {
            "element_layout" => Ok(listing(turn, caller)),
            "group_create" => (|| {
                let direction = direction.ok_or("Give `direction`: vertical or horizontal.")?;
                let ids = pictures(turn, arguments, caller)?;
                let group = ImageGroup::new(direction, color.unwrap_or(ImageGroup::COLORS[0]), ids.clone());
                let id = group.id;
                turn.set_image_group(group);
                let name = turn.image_groups.iter().find(|group| group.id == id).map(|group| group.name.clone()).unwrap_or_default();
                Ok(format!("Made “{name}” with {} in a {}.", ids.len(), if direction == Direction::Vertical { "column" } else { "row" }))
            })(),
            "group_edit" => (|| {
                let mut group = group(turn, arguments, caller).ok_or(NO_GROUP)?;
                if arguments.contains_key("elements") {
                    group.members = pictures(turn, arguments, caller)?;
                }
                group.direction = direction.unwrap_or(group.direction);
                group.color = color.map_or(group.color, str::to_string);
                let name = group.name.clone();
                turn.set_image_group(group);
                Ok(format!("Changed “{name}”."))
            })(),
            "group_remove" => group(turn, arguments, caller).ok_or(NO_GROUP.to_string()).map(|group| {
                turn.remove_image_group(group.id);
                format!("Dissolved “{}”; its pictures stay where they are.", group.name)
            }),
            _ => return move_element(turn, arguments, caller, reply),
        };
        reply.send(result.map_or_else(|refusal: String| ToolResult::error(refusal), ToolResult::text))
    }
}
