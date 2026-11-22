-- An account's catalog: its organizations, projects and worktrees per host, as one document
-- the boards write and the server never reads into (docs/catalog.md), so it can be sealed later.
CREATE TABLE catalog (
  account_id INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  document BLOB NOT NULL
);
