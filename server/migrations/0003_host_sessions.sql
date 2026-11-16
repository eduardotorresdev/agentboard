-- A session a host signed in with serves that host only (NULL: a board's session).
ALTER TABLE sessions ADD COLUMN host_id TEXT;
