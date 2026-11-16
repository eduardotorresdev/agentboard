use std::path::PathBuf;

use connections::Uuid;

use crate::image_card::ImageFiles;
use crate::orchestrator::{Orchestrator, Store};

/// Keeping the image and video records whole across older builds.
impl Store {
    /// At launch: videos an older build saved without their length get it back. Nothing the user
    /// named is rewritten (names are cleaned where they are shown and sent). Files in the images
    /// folder are never deleted here: a core whose database doesn't know them (a test, another
    /// build, a database that failed to open) can't tell an orphan from someone else's picture.
    pub(crate) fn tidy_media(&mut self) {
        let unmeasured: Vec<(Uuid, PathBuf)> = self.images.iter().filter(|record| record.is_video() && record.duration.is_none()).map(|record| (record.id, ImageFiles::url(&record.file, &self.data_folder))).collect();
        let (false, Some(tools)) = (unmeasured.is_empty(), self.video_tools()) else { return };
        let handle = self.handle.clone();
        std::thread::spawn(move || {
            for (id, path) in unmeasured {
                if let Some((_, duration)) = ImageFiles::video_info(&path, &tools) {
                    handle.post(move |orchestrator: &mut Orchestrator, server| orchestrator.turn(server).update_image(id, None, |image| image.duration = Some(duration)));
                }
            }
        });
    }
}
