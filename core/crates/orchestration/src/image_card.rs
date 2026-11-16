use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use connections::{Rect, Size, Uuid};

use crate::board_protocol::{rect, size};
use crate::cards::{default_organization, unique_name};

/// An image on the board: a picture the user pasted, picked or dropped, or one an agent made
/// (a screenshot, a chart). The core keeps it, so agents use it while no board runs. Agents
/// connected to it see its pixels with `image_read`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageRecord {
    pub id: Uuid,
    pub worktree: String,
    /// How the image is titled and how connected agents address it; unique among the images of
    /// its worktree.
    pub name: String,
    /// The whole card: `TITLE_HEIGHT` of title bar above the picture.
    #[serde(with = "rect")]
    pub frame: Rect,
    /// The picture's file name inside `ImageFiles::folder`. Replacing the picture gives it
    /// a new file name, which is how boards know to load it again.
    pub file: String,
    /// The picture's size in pixels.
    #[serde(with = "size")]
    pub pixel_size: Size,
    /// The organization it was added in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization: Option<Uuid>,
    /// Seconds of video when the card plays one (see `ImageFiles::store_video`). A build that
    /// predates videos may have saved the card without it, so `is_video` reads the file instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

impl ImageRecord {
    /// The title bar above the picture.
    pub const TITLE_HEIGHT: f64 = 32.0;
    /// The longer side of the picture on a new card.
    pub const INITIAL_SIDE: f64 = 480.0;
    /// The narrowest a card gets.
    pub const MINIMUM_WIDTH: f64 = 160.0;

    /// Whether the stored file is a video: told by its extension, which the store chose.
    pub fn is_video(&self) -> bool {
        extension(Path::new(&self.file)).is_some_and(|extension| ImageFiles::VIDEO_EXTENSIONS.contains(&extension.as_str()))
    }

    pub fn organization_id(&self) -> Uuid {
        self.organization.unwrap_or(default_organization())
    }

    /// The size of a new card showing a picture of `pixel_size`: one point per pixel, scaled
    /// down so the longer side is at most `INITIAL_SIDE` and never scaled up, at least
    /// `MINIMUM_WIDTH` wide, plus the title bar.
    pub fn card_size(pixel_size: Size) -> Size {
        let longer = pixel_size.width.max(pixel_size.height).max(1.0);
        Self::card_size_wide(pixel_size.width.min(pixel_size.width * Self::INITIAL_SIDE / longer), pixel_size)
    }

    /// The card `width` wide (at least `MINIMUM_WIDTH`) that shows a picture of `pixel_size`
    /// without bars: every resize goes through this, so the proportion never changes.
    pub fn card_size_wide(width: f64, pixel_size: Size) -> Size {
        let width = width.max(Self::MINIMUM_WIDTH);
        Size::new(width, (width * pixel_size.height / pixel_size.width.max(1.0)).round() + Self::TITLE_HEIGHT)
    }

    /// `base`, or `base 2`, `base 3`… whichever no image in `others` is called.
    pub fn unique_name<'a>(base: &str, others: impl IntoIterator<Item = &'a ImageRecord>) -> String {
        unique_name(base, others.into_iter().map(|other| other.name.as_str()))
    }
}

/// A path's extension, lowercased.
pub(crate) fn extension(path: &Path) -> Option<String> {
    path.extension().map(|extension| extension.to_string_lossy().to_lowercase())
}

/// Where the pictures of the board's images live, and how one gets in: the board (paste, file
/// picker, drop) and the core (`image_create`, `image_replace`) both store through here, so
/// both refuse the same files.
pub struct ImageFiles;

#[derive(Clone, Debug, PartialEq)]
pub enum Failure {
    Missing,
    /// A folder, a device, a pipe: not a regular file.
    NotAFile,
    TooLarge,
    NotAnImage,
    /// A video that can't be played, or not MP4, MOV or M4V.
    NotPlayable,
    /// This host has no ffmpeg and ffprobe to read videos with.
    NoVideoTools,
    Other(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Stored {
    pub file: String,
    pub pixel_size: Size,
    /// Seconds, for a video.
    pub duration: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Picture,
    Video,
}

/// A source file as it really is: symlinks resolved once, its kind decided from the resolved
/// file, so a link named `x.png` to a video is a video everywhere.
#[derive(Clone, Debug)]
pub struct Inspected {
    pub path: PathBuf,
    pub kind: Kind,
    pub bytes: u64,
}

impl ImageFiles {
    /// The largest file taken.
    pub const MAXIMUM_BYTES: u64 = 20 * 1024 * 1024;
    /// The longer side of what `image_read` gives an agent.
    pub const READ_SIDE: u32 = 1568;

    pub fn folder(data_folder: &Path) -> PathBuf {
        data_folder.join("images")
    }

    pub fn url(file: &str, data_folder: &Path) -> PathBuf {
        Self::folder(data_folder).join(file)
    }

    /// Whether `file` is a plain file name: what a record may name inside the images folder,
    /// never a path out of it.
    pub fn is_plain_name(file: &str) -> bool {
        !file.is_empty() && file != "." && file != ".." && !file.contains('/') && !file.contains('\0')
    }

    pub fn inspect(source: &Path) -> Result<Inspected, Failure> {
        let path = source.canonicalize().map_err(|_| Failure::Missing)?;
        let metadata = path.metadata().map_err(|_| Failure::NotAFile)?;
        if !metadata.is_file() {
            return Err(Failure::NotAFile);
        }
        Ok(Inspected { kind: if Self::is_video_file(&path) { Kind::Video } else { Kind::Picture }, bytes: metadata.len(), path })
    }

    /// Copies the picture at `source` into the folder under a new name, as it is. A video is
    /// refused here.
    pub fn store_file(source: &Path, data_folder: &Path) -> Result<Stored, Failure> {
        let file = Self::inspect(source)?;
        if file.kind != Kind::Picture {
            return Err(Failure::NotAnImage);
        }
        Self::store_picture(&file, data_folder)
    }

    pub(crate) fn store_picture(file: &Inspected, data_folder: &Path) -> Result<Stored, Failure> {
        if file.bytes > Self::MAXIMUM_BYTES {
            return Err(Failure::TooLarge);
        }
        Self::store(&std::fs::read(&file.path).map_err(|_| Failure::Missing)?, data_folder)
    }

    /// Stores `data` (a pasted picture) under a new name, as it is.
    pub fn store(data: &[u8], data_folder: &Path) -> Result<Stored, Failure> {
        if data.len() as u64 > Self::MAXIMUM_BYTES {
            return Err(Failure::TooLarge);
        }
        let (pixel_size, kind) = Self::header(data).ok_or(Failure::NotAnImage)?;
        let file = format!("{}.{}", Uuid::new(), file_extension(kind));
        let stored = |error: std::io::Error| Failure::Other(error.to_string());
        std::fs::create_dir_all(Self::folder(data_folder)).map_err(stored)?;
        std::fs::write(Self::url(&file, data_folder), data).map_err(stored)?;
        Ok(Stored { file, pixel_size, duration: None })
    }

    /// The first frame's size and the format, read from the header without decoding the bitmap.
    // shortcut: the size is as stored, not turned by EXIF orientation as ImageIO gives it (a
    // phone photo taken upright reports width and height swapped), read the tag when cards of such photos matter on hosts.
    fn header(data: &[u8]) -> Option<(Size, imagesize::ImageType)> {
        let size = imagesize::blob_size(data).ok()?;
        let kind = imagesize::image_type(data).ok()?;
        (size.width > 0 && size.height > 0).then(|| (Size::new(size.width as f64, size.height as f64), kind))
    }

    pub fn remove(file: &str, data_folder: &Path) {
        let _ = std::fs::remove_file(Self::url(file, data_folder));
    }

    /// The picture for an agent: as stored when it is a PNG, JPEG, GIF or WebP no larger than
    /// `READ_SIDE` on its longer side, else scaled down to that and encoded as JPEG when the
    /// source is one and PNG otherwise. None when the file is gone or unreadable.
    // shortcut: only PNG and JPEG are scaled down (ImageIO decodes every format): a larger GIF,
    // WebP, TIFF or HEIC can't be read, add the `image` features for them if agents meet such files.
    pub fn reading(file: &str, data_folder: &Path) -> Option<(Vec<u8>, String)> {
        use imagesize::ImageType;
        let data = std::fs::read(Self::url(file, data_folder)).ok()?;
        let (size, kind) = Self::header(&data)?;
        let passed = match kind {
            ImageType::Png => Some("image/png"),
            ImageType::Jpeg => Some("image/jpeg"),
            ImageType::Gif => Some("image/gif"),
            ImageType::Webp => Some("image/webp"),
            _ => None,
        };
        let side = Self::READ_SIDE.min(size.width.max(size.height) as u32);
        if let (Some(mime_type), true) = (passed, size.width.max(size.height) <= Self::READ_SIDE as f64) {
            return Some((data, mime_type.to_string()));
        }
        let picture = image::load_from_memory(&data).ok()?.thumbnail(side, side);
        let mut encoded = std::io::Cursor::new(Vec::new());
        if kind == ImageType::Jpeg {
            picture.to_rgb8().write_to(&mut encoded, image::ImageFormat::Jpeg).ok()?;
            Some((encoded.into_inner(), "image/jpeg".into()))
        } else {
            picture.write_to(&mut encoded, image::ImageFormat::Png).ok()?;
            Some((encoded.into_inner(), "image/png".into()))
        }
    }
}

/// The extension a stored picture gets, as `UTType.preferredFilenameExtension` names its format.
fn file_extension(kind: imagesize::ImageType) -> &'static str {
    use imagesize::ImageType;
    match kind {
        ImageType::Png => "png",
        ImageType::Jpeg => "jpeg",
        ImageType::Gif => "gif",
        ImageType::Webp => "webp",
        ImageType::Bmp => "bmp",
        ImageType::Tiff => "tiff",
        ImageType::Heif(_) => "heic",
        ImageType::Ico => "ico",
        _ => "img",
    }
}
