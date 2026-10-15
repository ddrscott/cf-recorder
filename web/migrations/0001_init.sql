CREATE TABLE login_codes (
  email TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  sent_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX sessions_expires ON sessions (expires_at);

CREATE TABLE login_limits (
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  guesses INTEGER NOT NULL
);

-- One row per synced call, rebuilt from its meeting.json on every upload.
CREATE TABLE calls (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  their_name TEXT NOT NULL,
  my_name TEXT NOT NULL,
  started_at TEXT NOT NULL,
  duration REAL NOT NULL,
  lines INTEGER NOT NULL,
  preview TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX calls_started ON calls (started_at);
