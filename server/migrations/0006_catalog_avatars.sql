-- Organizations' avatars, outside the catalog document: an image (at most 64 KiB) and its own
-- version per organization, so a board fetches only the ones that changed (docs/catalog.md).
CREATE TABLE catalog_avatars (
  account_id INTEGER NOT NULL,
  organization TEXT NOT NULL, -- lowercase UUID
  version INTEGER NOT NULL,
  image BLOB, -- NULL: removed (the version stays, so a stale writer can't bring it back)
  PRIMARY KEY (account_id, organization)
);
