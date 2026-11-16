CREATE TABLE accounts (
  id INTEGER PRIMARY KEY, -- GitHub's numeric user id
  login TEXT NOT NULL,
  name TEXT,
  avatar_url TEXT
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY, -- hex SHA-256 of the bearer token
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL
);

CREATE TABLE hosts (
  id TEXT PRIMARY KEY, -- lowercase UUID chosen by the host
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  version TEXT NOT NULL,
  public_key TEXT NOT NULL,
  online INTEGER NOT NULL DEFAULT 0,
  last_seen INTEGER -- Unix seconds, NULL until the host first listens
);
CREATE INDEX hosts_account ON hosts(account_id);

CREATE TABLE login_rate (
  ip TEXT NOT NULL,
  minute INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (ip, minute)
);
