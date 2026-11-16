use std::collections::HashSet;
use std::path::Path;

use rusqlite::types::ValueRef;
use rusqlite::{params, Connection as Sqlite, Row};
use serde::Deserialize;

use connections::{Connection, Rect, Side, Size, Uuid};

use crate::cards::{AgentRecord, RunnerSpec};
use crate::image_card::ImageRecord;
use crate::post_it::PostItRecord;

pub type Result<T> = rusqlite::Result<T>;

/// The cards and the lines between elements, in the board's SQLite file. Only the core writes
/// these tables; the board keeps the rest of the file (projects, browsers…). The same file,
/// schema and column encodings as the Swift core's, so a data folder serves either.
pub struct CardDatabase {
    db: Sqlite,
}

/// Text as `sqlite3_column_text` gives it: none for NULL, and a number as its text.
fn text(row: &Row, column: usize) -> Option<String> {
    match row.get_ref(column).ok()? {
        ValueRef::Null => None,
        ValueRef::Text(text) | ValueRef::Blob(text) => Some(String::from_utf8_lossy(text).into_owned()),
        ValueRef::Integer(number) => Some(number.to_string()),
        ValueRef::Real(number) => Some(number.to_string()),
    }
}

/// A number as `sqlite3_column_double` gives it; none for NULL.
fn real(row: &Row, column: usize) -> Option<f64> {
    match row.get_ref(column).ok()? {
        ValueRef::Real(number) => Some(number),
        ValueRef::Integer(number) => Some(number as f64),
        ValueRef::Text(text) => Some(std::str::from_utf8(text).ok().and_then(|text| text.parse().ok()).unwrap_or(0.0)),
        _ => None,
    }
}

fn uuid(row: &Row, column: usize) -> Option<Uuid> {
    text(row, column).as_deref().and_then(Uuid::parse)
}

/// The frame in columns `first` to `first + 3`: x, y, width, height.
fn frame(row: &Row, first: usize) -> Rect {
    let value = |offset| real(row, first + offset).unwrap_or(0.0);
    Rect::new(value(0), value(1), value(2), value(3))
}

impl CardDatabase {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        let database = Self { db: Sqlite::open(path)? };
        // The board has the same file open.
        database.db.busy_timeout(std::time::Duration::from_millis(3000))?;
        database.db.execute_batch(
            "CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                kind TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS connections (
                id TEXT PRIMARY KEY,
                a TEXT NOT NULL,
                b TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS postits (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                name TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL,
                text TEXT NOT NULL,
                editor TEXT,
                editor_name TEXT NOT NULL,
                edited REAL
            );
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY,
                worktree TEXT NOT NULL,
                name TEXT NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL,
                width REAL NOT NULL, height REAL NOT NULL,
                file TEXT NOT NULL,
                pixel_width REAL NOT NULL, pixel_height REAL NOT NULL,
                organization TEXT
            )",
        )?;
        // Before migrating notes blocks, which saves post-its with it.
        database.add_columns("postits", "organization", "ALTER TABLE postits ADD COLUMN organization TEXT")?;
        database.migrate_notes_blocks()?;
        // Videos share the images table; a picture has no duration.
        database.add_columns("images", "duration", "ALTER TABLE images ADD COLUMN duration REAL")?;
        database.add_columns("agents", "name", "ALTER TABLE agents ADD COLUMN name TEXT")?;
        // Runner cards: what they run, where, and the agent that started them.
        database.add_columns("agents", "command", "ALTER TABLE agents ADD COLUMN command TEXT; ALTER TABLE agents ADD COLUMN directory TEXT; ALTER TABLE agents ADD COLUMN owner TEXT")?;
        database.add_columns("agents", "organization", "ALTER TABLE agents ADD COLUMN organization TEXT")?;
        database.add_columns("agents", "orchestrates", "ALTER TABLE agents ADD COLUMN orchestrates INTEGER")?;
        database.add_columns("agents", "conversation", "ALTER TABLE agents ADD COLUMN conversation TEXT")?;
        database.add_columns("connections", "a_side", "ALTER TABLE connections ADD COLUMN a_side INTEGER; ALTER TABLE connections ADD COLUMN b_side INTEGER")?;
        Ok(database)
    }

    /// Runs `sql` when `table` has no `column` yet.
    fn add_columns(&self, table: &str, column: &str, sql: &str) -> Result<()> {
        if self.columns(table)?.contains(column) {
            return Ok(());
        }
        match self.db.execute_batch(sql) {
            // Another process (the board, another core) may add it between the check and here; that is success too.
            Err(error) if error.to_string().contains("duplicate column") => Ok(()),
            done => done,
        }
    }

    fn columns(&self, table: &str) -> Result<HashSet<String>> {
        let mut statement = self.db.prepare(&format!("PRAGMA table_info({table})"))?;
        let names = statement.query_map([], |row| row.get::<_, String>(1))?;
        names.collect()
    }

    /// Every row of `sql` that `read` makes a record of; one it can't read is left out.
    fn rows<T>(&self, sql: &str, read: impl Fn(&Row) -> Option<T>) -> Result<Vec<T>> {
        let mut statement = self.db.prepare(sql)?;
        let mut rows = statement.query([])?;
        let mut result = Vec::new();
        while let Some(row) = rows.next()? {
            result.extend(read(row));
        }
        Ok(result)
    }

    pub fn agents(&self) -> Result<Vec<AgentRecord>> {
        self.rows("SELECT id, worktree, kind, x, y, width, height, name, command, directory, owner, organization, orchestrates, conversation FROM agents ORDER BY rowid", |row| {
            let worktree = text(row, 1)?;
            let runner = text(row, 8).map(|command| RunnerSpec { command, directory: text(row, 9).unwrap_or_else(|| worktree.clone()), owner: uuid(row, 10) });
            Some(AgentRecord {
                id: uuid(row, 0)?,
                provider_id: text(row, 2)?,
                name: text(row, 7).unwrap_or_default(),
                frame: frame(row, 3),
                runner,
                organization: uuid(row, 11),
                orchestrates: real(row, 12).map(|flag| flag != 0.0),
                conversation: uuid(row, 13),
                worktree,
            })
        })
    }

    pub fn save_agent(&self, agent: &AgentRecord) -> Result<()> {
        let runner = agent.runner.as_ref();
        self.db.execute(
            "INSERT OR REPLACE INTO agents (id, worktree, kind, x, y, width, height, name, command, directory, owner, organization, orchestrates, conversation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                agent.id.to_string(),
                agent.worktree,
                agent.provider_id,
                agent.frame.min_x(),
                agent.frame.min_y(),
                agent.frame.width(),
                agent.frame.height(),
                agent.name,
                runner.map(|runner| &runner.command),
                runner.map(|runner| &runner.directory),
                runner.and_then(|runner| runner.owner).map(|owner| owner.to_string()),
                agent.organization.map(|organization| organization.to_string()),
                agent.orchestrates.map(i32::from),
                agent.conversation.map(|conversation| conversation.to_string()),
            ],
        )?;
        Ok(())
    }

    pub fn delete_agent(&self, id: Uuid) -> Result<()> {
        self.db.execute("DELETE FROM agents WHERE id = ?", [id.to_string()]).map(|_| ())
    }

    /// Post-its, in the order they were added.
    pub fn post_its(&self) -> Result<Vec<PostItRecord>> {
        self.rows("SELECT id, worktree, name, x, y, width, height, text, editor, editor_name, edited, organization FROM postits ORDER BY rowid", |row| {
            Some(PostItRecord {
                id: uuid(row, 0)?,
                worktree: text(row, 1)?,
                name: text(row, 2)?,
                frame: frame(row, 3),
                text: text(row, 7)?,
                editor: uuid(row, 8),
                editor_name: text(row, 9)?,
                edited: real(row, 10),
                organization: uuid(row, 11),
            })
        })
    }

    pub fn save_post_it(&self, post_it: &PostItRecord) -> Result<()> {
        self.db.execute(
            "INSERT OR REPLACE INTO postits (id, worktree, name, x, y, width, height, text, editor, editor_name, edited, organization)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                post_it.id.to_string(),
                post_it.worktree,
                post_it.name,
                post_it.frame.min_x(),
                post_it.frame.min_y(),
                post_it.frame.width(),
                post_it.frame.height(),
                post_it.text,
                post_it.editor.map(|editor| editor.to_string()),
                post_it.editor_name,
                post_it.edited,
                post_it.organization.map(|organization| organization.to_string()),
            ],
        )?;
        Ok(())
    }

    pub fn delete_post_it(&self, id: Uuid) -> Result<()> {
        self.db.execute("DELETE FROM postits WHERE id = ?", [id.to_string()]).map(|_| ())
    }

    /// Images, in the order they were added.
    pub fn images(&self) -> Result<Vec<ImageRecord>> {
        self.rows("SELECT id, worktree, name, x, y, width, height, file, pixel_width, pixel_height, organization, duration FROM images ORDER BY rowid", |row| {
            Some(ImageRecord {
                id: uuid(row, 0)?,
                worktree: text(row, 1)?,
                name: text(row, 2)?,
                frame: frame(row, 3),
                file: text(row, 7)?,
                pixel_size: Size::new(real(row, 8).unwrap_or(0.0), real(row, 9).unwrap_or(0.0)),
                organization: uuid(row, 10),
                duration: real(row, 11),
            })
        })
    }

    pub fn save_image(&self, image: &ImageRecord) -> Result<()> {
        self.db.execute(
            "INSERT OR REPLACE INTO images (id, worktree, name, x, y, width, height, file, pixel_width, pixel_height, organization, duration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                image.id.to_string(),
                image.worktree,
                image.name,
                image.frame.min_x(),
                image.frame.min_y(),
                image.frame.width(),
                image.frame.height(),
                image.file,
                image.pixel_size.width,
                image.pixel_size.height,
                image.organization.map(|organization| organization.to_string()),
                image.duration,
            ],
        )?;
        Ok(())
    }

    pub fn delete_image(&self, id: Uuid) -> Result<()> {
        self.db.execute("DELETE FROM images WHERE id = ?", [id.to_string()]).map(|_| ())
    }

    /// The notes blocks of the build before become post-its with the same ids (so their lines
    /// hold), their notes as a markdown list; their statuses are dropped.
    fn migrate_notes_blocks(&self) -> Result<()> {
        if self.columns("notes")?.is_empty() {
            return Ok(());
        }
        #[derive(Deserialize)]
        struct Entry {
            kind: String,
            text: String,
        }
        let blocks = self.rows("SELECT id, worktree, name, x, y, width, height, entries FROM notes ORDER BY rowid", |row| {
            let entries: Vec<Entry> = serde_json::from_str(&text(row, 7).unwrap_or_default()).unwrap_or_default();
            let notes: Vec<String> = entries.iter().filter(|entry| entry.kind == "note").map(|entry| format!("- {}", entry.text.replace('\n', "\n  "))).collect();
            Some(PostItRecord { text: notes.join("\n"), ..PostItRecord::new(uuid(row, 0)?, text(row, 1)?, text(row, 2)?, frame(row, 3)) })
        })?;
        for block in &blocks {
            self.save_post_it(block)?;
        }
        self.db.execute_batch("DROP TABLE notes")
    }

    /// Ids of the elements the board stored (browsers, file trees), so lines to them survive
    /// loading before any board has said which elements it has.
    /// Fails when a table that exists can't be read; one the app hasn't created yet is empty.
    pub fn browser_ids(&self) -> Result<HashSet<Uuid>> {
        let mut result = HashSet::new();
        for table in ["browsers", "file_trees"] {
            if !self.db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")?.exists([table])? {
                continue;
            }
            result.extend(self.rows(&format!("SELECT id FROM {table}"), |row| uuid(row, 0))?);
        }
        Ok(result)
    }

    /// Lines between cards, in the order they were drawn.
    pub fn connections(&self) -> Result<Vec<Connection>> {
        let side = |row: &Row, column| real(row, column).and_then(|side| Side::try_from(side as u8).ok().filter(|_| (0.0..4.0).contains(&side)));
        self.rows("SELECT id, a, b, a_side, b_side FROM connections ORDER BY rowid", |row| Some(Connection { id: uuid(row, 0)?, a: uuid(row, 1)?, b: uuid(row, 2)?, a_side: side(row, 3), b_side: side(row, 4) }))
    }

    /// Replaces the stored lines with `connections`, keeping their order.
    pub fn save_connections(&mut self, connections: &[Connection]) -> Result<()> {
        let transaction = self.db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        transaction.execute("DELETE FROM connections", [])?;
        {
            let mut insert = transaction.prepare("INSERT INTO connections (id, a, b, a_side, b_side) VALUES (?, ?, ?, ?, ?)")?;
            for connection in connections {
                insert.execute(params![connection.id.to_string(), connection.a.to_string(), connection.b.to_string(), connection.a_side.map(|side| side as u8), connection.b_side.map(|side| side as u8)])?;
            }
        }
        // Dropped without this (an insert failed), it rolls back.
        transaction.commit()
    }
}
