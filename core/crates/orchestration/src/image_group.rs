use serde::{Deserialize, Serialize};

use connections::{BoardName, Point, Rect, Size, Uuid};

use crate::board_protocol::{only, BoardEvent};
use crate::image_card::ImageRecord;
use crate::orchestrator::{Store, Turn};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    /// One column: every card as wide as the group's `extent`.
    Vertical,
    /// One row: every picture as tall as the group's `extent`.
    Horizontal,
}

/// An organizational group: images and videos kept in one column or one row, snapped to the
/// group's grid, on a light panel of a palette color. Only pictures join one, each at most one.
/// The core lays the members out, so agents and every board see the same places.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ImageGroup {
    pub id: Uuid,
    /// How agents address it; unique among the groups.
    pub name: String,
    pub direction: Direction,
    /// One of `COLORS`.
    pub color: String,
    /// The first member's top left corner; none until the core places the group around its members.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "point")]
    pub origin: Option<Point>,
    /// The grid's cell: the cards' width in a column, the pictures' height in a row. None until
    /// the core takes it from the first member (again after the direction changes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extent: Option<f64>,
    /// The images and videos, in the order they are laid out.
    pub members: Vec<Uuid>,
}

/// `CGPoint?` on the wire: `[x, y]`, left out when none.
mod point {
    use connections::Point;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(point: &Option<Point>, serializer: S) -> Result<S::Ok, S::Error> {
        point.map(|point| [point.x, point.y]).serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Point>, D::Error> {
        Ok(<Option<[f64; 2]>>::deserialize(deserializer)?.map(|[x, y]| Point::new(x, y)))
    }
}

impl ImageGroup {
    /// The palette a group's panel is picked from (the board has the colors).
    pub const COLORS: [&'static str; 5] = ["blue", "amber", "rose", "violet", "gray"];
    /// The space between two members.
    pub const GAP: f64 = 16.0;
    /// The panel around the members.
    pub const PADDING: f64 = 16.0;

    pub fn new(direction: Direction, color: &str, members: Vec<Uuid>) -> Self {
        Self { id: Uuid::new(), name: String::new(), direction, color: color.to_string(), origin: None, extent: None, members }
    }

    /// Where each member goes, given the pictures' pixel sizes in member order.
    pub fn frames(&self, pixel_sizes: &[Size]) -> Vec<Rect> {
        let vertical = self.direction == Direction::Vertical;
        let mut point = self.origin.unwrap_or_default();
        let extent = self.extent.unwrap_or(ImageRecord::MINIMUM_WIDTH);
        pixel_sizes
            .iter()
            .map(|pixels| {
                let width = if vertical { extent } else { (extent * pixels.width / pixels.height.max(1.0)).round() };
                let frame = Rect::at(point, ImageRecord::card_size_wide(width, *pixels));
                if vertical {
                    point.y = frame.max_y() + Self::GAP;
                } else {
                    point.x = frame.max_x() + Self::GAP;
                }
                frame
            })
            .collect()
    }
}

impl Store {
    pub(crate) fn image_group_of(&self, image: Uuid) -> Option<&ImageGroup> {
        self.image_groups.iter().find(|group| group.members.contains(&image))
    }
}

impl Turn<'_> {
    /// The groups whose pictures are on `caller`'s board.
    pub(crate) fn image_groups_on_board_of(&self, caller: Uuid) -> Vec<ImageGroup> {
        let on_board: Vec<Uuid> = self.bus.elements_on_board_of(caller, &self.board).iter().map(|element| element.id).collect();
        self.image_groups.iter().filter(|group| group.members.iter().any(|member| on_board.contains(member))).cloned().collect()
    }

    /// Makes or changes a group: keeps only the pictures of its first member's board, takes them
    /// out of any other group, fills what is none from the members, and lays everything out.
    /// A group left without members goes.
    pub(crate) fn set_image_group(&mut self, mut group: ImageGroup) {
        let mut records: Vec<ImageRecord> = Vec::new();
        for id in &group.members {
            let Some(record) = self.image(*id) else { continue };
            let elsewhere = records.first().is_some_and(|first| first.worktree != record.worktree || first.organization_id() != record.organization_id());
            if !elsewhere && !records.iter().any(|kept| kept.id == record.id) {
                records.push(record.clone());
            }
        }
        if records.is_empty() {
            return self.remove_image_group(group.id);
        }
        let old = self.image_groups.iter().find(|other| other.id == group.id).cloned();
        let vertical = group.direction == Direction::Vertical;
        if old.is_none() {
            // A new group reads in the order the pictures already sit along its direction.
            let along = |record: &ImageRecord| if vertical { record.frame.min_y() } else { record.frame.min_x() };
            records.sort_by(|a, b| along(a).total_cmp(&along(b)));
        }
        group.members = records.iter().map(|record| record.id).collect();
        if !ImageGroup::COLORS.contains(&group.color.as_str()) {
            group.color = old.as_ref().map_or(ImageGroup::COLORS[0].to_string(), |old| old.color.clone());
        }
        if old.as_ref().is_some_and(|old| old.direction != group.direction) {
            group.extent = None;
        }
        let first = records[0].frame;
        group.extent = group.extent.or(Some(if vertical { first.width() } else { first.height() - ImageRecord::TITLE_HEIGHT }));
        group.origin = group.origin.or_else(|| {
            let least = |values: &dyn Fn(&ImageRecord) -> f64| records.iter().map(values).fold(f64::INFINITY, f64::min);
            Some(Point::new(least(&|record| record.frame.min_x()), least(&|record| record.frame.min_y())))
        });
        group.name = BoardName::clean(&group.name).or(old.map(|old| old.name)).unwrap_or_else(|| {
            (1..).map(|number| format!("Group {number}")).find(|name| !self.image_groups.iter().any(|other| &other.name == name)).unwrap_or_default()
        });
        let groups = &mut self.board.store.image_groups;
        for other in groups.iter_mut().filter(|other| other.id != group.id) {
            other.members.retain(|member| !group.members.contains(member));
        }
        match groups.iter_mut().find(|other| other.id == group.id) {
            Some(slot) => *slot = group,
            None => groups.push(group),
        }
        groups.retain(|group| !group.members.is_empty());
        self.image_groups_changed();
    }

    /// Forgets the group; its pictures stay where they are.
    pub(crate) fn remove_image_group(&mut self, id: Uuid) {
        if self.image_groups.iter().any(|group| group.id == id) {
            self.image_groups.retain(|group| group.id != id);
            self.image_groups_changed();
        }
    }

    /// A removed picture leaves its group.
    pub(crate) fn image_left_board(&mut self, id: Uuid) {
        if self.image_group_of(id).is_none() {
            return;
        }
        self.image_groups.iter_mut().for_each(|group| group.members.retain(|member| *member != id));
        self.image_groups.retain(|group| !group.members.is_empty());
        self.image_groups_changed();
    }

    /// A grouped picture was moved or resized on its own (dragged on a board, `element_move`,
    /// `image_resize`): the whole group follows, so the grid holds. Moving it moves the group;
    /// resizing it resizes the grid's cell.
    pub(crate) fn image_frame_changed(&mut self, id: Uuid, before: Rect) {
        let Some(now) = self.image(id).map(|image| image.frame).filter(|now| *now != before) else { return };
        let Some(group) = self.board.store.image_groups.iter_mut().find(|group| group.members.contains(&id)) else { return };
        if let Some(origin) = group.origin {
            group.origin = Some(Point::new(origin.x + now.min_x() - before.min_x(), origin.y + now.min_y() - before.min_y()));
        }
        if now.size != before.size {
            group.extent = Some(if group.direction == Direction::Vertical { now.width() } else { now.height() - ImageRecord::TITLE_HEIGHT });
        }
        self.image_groups_changed();
    }

    /// Puts every grouped picture on its group's grid; every board hears of the ones that moved.
    pub(crate) fn layout_image_groups(&mut self) {
        for group in self.image_groups.clone() {
            let records: Vec<(Uuid, Size)> = group.members.iter().filter_map(|member| self.image(*member)).map(|image| (image.id, image.pixel_size)).collect();
            let frames = group.frames(&records.iter().map(|record| record.1).collect::<Vec<_>>());
            for ((id, _), frame) in records.into_iter().zip(frames) {
                self.update_image(id, None, |image| image.frame = frame);
            }
        }
    }

    fn image_groups_changed(&mut self) {
        // Kept as the Swift core writes it: a JSON array of groups.
        let _ = std::fs::write(self.data_folder.join("image-groups.json"), serde_json::to_vec(&self.image_groups).unwrap_or_default());
        self.layout_image_groups();
        self.broadcast(&BoardEvent::ImageGroups(only(self.image_groups.clone())), None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn members_snap_to_the_grid() {
        let pixels = [Size::new(800.0, 400.0), Size::new(400.0, 400.0)];
        let mut group = ImageGroup { origin: Some(Point::new(10.0, 20.0)), extent: Some(200.0), ..ImageGroup::new(Direction::Vertical, "blue", Vec::new()) };
        assert_eq!(group.frames(&pixels), [Rect::new(10.0, 20.0, 200.0, 132.0), Rect::new(10.0, 168.0, 200.0, 232.0)]);
        group.direction = Direction::Horizontal;
        assert_eq!(group.frames(&pixels), [Rect::new(10.0, 20.0, 400.0, 232.0), Rect::new(426.0, 20.0, 200.0, 232.0)]);
    }
}
