-- An account's vault: one sealed manifest and the sealed chunks it names (docs/hosts.md).
CREATE TABLE vault (
  account_id INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  manifest BLOB NOT NULL
);

CREATE TABLE vault_chunks (
  account_id INTEGER NOT NULL,
  id TEXT NOT NULL,
  size INTEGER NOT NULL,
  data BLOB NOT NULL,
  PRIMARY KEY (account_id, id)
);
