import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id           TEXT PRIMARY KEY,
  provider     TEXT NOT NULL,
  provider_sub TEXT NOT NULL,
  name         TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  UNIQUE (provider, provider_sub)
);

CREATE TABLE IF NOT EXISTS invites (
  code       TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL
);

-- Short-lived record of who opened which invite link, so a freshly installed app
-- can find the invite that brought it there. Only a salted hash of the IP is kept.
CREATE TABLE IF NOT EXISTS invite_visits (
  ip_hash    TEXT NOT NULL,
  code       TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS invite_visits_ip ON invite_visits (ip_hash, created_at DESC);

CREATE TABLE IF NOT EXISTS pairs (
  id         TEXT PRIMARY KEY,
  user_a     TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  user_b     TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  user_id      TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  apns_token   TEXT NOT NULL,
  widget_token TEXT
);

CREATE TABLE IF NOT EXISTS doodles (
  id         TEXT PRIMARY KEY,
  pair_id    TEXT NOT NULL REFERENCES pairs(id) ON DELETE CASCADE,
  sender_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  has_photo  INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS doodles_pair_created ON doodles (pair_id, created_at DESC);
`;

/** Open (and migrate) the database. Pass ":memory:" for tests. */
export function openDb(path: string): DatabaseSync {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA foreign_keys = ON");
  db.exec(SCHEMA);
  return db;
}
