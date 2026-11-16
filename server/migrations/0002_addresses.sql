-- Where a board may reach the host directly: a JSON array of "address:port" strings.
ALTER TABLE hosts ADD COLUMN addresses TEXT NOT NULL DEFAULT '[]';
