"""Local persistence for Hermes Dictation.

All transcript history, snippets, notes, and usage statistics stay in a small
SQLite database under the user's local data directory. The menubar process and
the local Hub server can safely share this store because each operation uses a
short-lived connection and the database runs in WAL mode.
"""

from __future__ import annotations

import re
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


DATA_DIR = Path.home() / ".local" / "share" / "hermes-dictation"
DB_PATH = DATA_DIR / "hermes.db"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _word_count(text: str) -> int:
    return len(re.findall(r"\b[\w’'-]+\b", text or ""))


class LocalStore:
    """Thread-safe, local-only store for Hermes user data."""

    def __init__(self, path: Path | str = DB_PATH):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(str(self.path), timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _initialize(self) -> None:
        with self._lock, self._connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    text TEXT NOT NULL,
                    raw_text TEXT NOT NULL DEFAULT '',
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    word_count INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_transcripts_created_at
                    ON transcripts(created_at DESC);

                CREATE TABLE IF NOT EXISTS snippets (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    trigger TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    value TEXT NOT NULL,
                    action TEXT NOT NULL DEFAULT 'insert',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS notes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_notes_updated_at
                    ON notes(updated_at DESC);
                """
            )

    @staticmethod
    def _row(row: Optional[sqlite3.Row]) -> Optional[dict[str, Any]]:
        return dict(row) if row is not None else None

    def add_transcript(
        self,
        text: str,
        raw_text: str = "",
        duration_seconds: float = 0,
        created_at: Optional[str] = None,
    ) -> Optional[int]:
        text = (text or "").strip()
        if not text:
            return None
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO transcripts
                    (created_at, text, raw_text, duration_seconds, word_count)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    created_at or _now(),
                    text,
                    raw_text or "",
                    max(0.0, float(duration_seconds or 0)),
                    _word_count(text),
                ),
            )
            return int(cursor.lastrowid)

    def list_transcripts(
        self, query: str = "", limit: int = 100, offset: int = 0
    ) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 500))
        offset = max(0, int(offset))
        with self._lock, self._connect() as connection:
            if query.strip():
                pattern = f"%{query.strip()}%"
                rows = connection.execute(
                    """
                    SELECT id, created_at, text, raw_text, duration_seconds, word_count
                    FROM transcripts
                    WHERE text LIKE ? OR raw_text LIKE ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ? OFFSET ?
                    """,
                    (pattern, pattern, limit, offset),
                ).fetchall()
            else:
                rows = connection.execute(
                    """
                    SELECT id, created_at, text, raw_text, duration_seconds, word_count
                    FROM transcripts
                    ORDER BY created_at DESC, id DESC
                    LIMIT ? OFFSET ?
                    """,
                    (limit, offset),
                ).fetchall()
            return [dict(row) for row in rows]

    def delete_transcript(self, transcript_id: int) -> None:
        with self._lock, self._connect() as connection:
            connection.execute("DELETE FROM transcripts WHERE id = ?", (int(transcript_id),))

    def stats(self) -> dict[str, Any]:
        month = datetime.now().strftime("%Y-%m")
        with self._lock, self._connect() as connection:
            totals = connection.execute(
                """
                SELECT COUNT(*) AS sessions,
                       COALESCE(SUM(word_count), 0) AS words,
                       COALESCE(SUM(duration_seconds), 0) AS seconds,
                       COALESCE(AVG(
                           CASE WHEN duration_seconds > 0
                           THEN word_count / (duration_seconds / 60.0) END
                       ), 0) AS average_wpm
                FROM transcripts
                """
            ).fetchone()
            monthly = connection.execute(
                """
                SELECT COUNT(*) AS sessions,
                       COALESCE(SUM(word_count), 0) AS words,
                       COALESCE(SUM(duration_seconds), 0) AS seconds,
                       COALESCE(AVG(
                           CASE WHEN duration_seconds > 0
                           THEN word_count / (duration_seconds / 60.0) END
                       ), 0) AS average_wpm
                FROM transcripts
                WHERE substr(created_at, 1, 7) = ?
                """,
                (month,),
            ).fetchone()
            daily = connection.execute(
                """
                SELECT substr(created_at, 1, 10) AS day,
                       SUM(word_count) AS words,
                       COUNT(*) AS sessions
                FROM transcripts
                GROUP BY substr(created_at, 1, 10)
                ORDER BY day DESC
                LIMIT 30
                """
            ).fetchall()

        return {
            "total": dict(totals),
            "month": dict(monthly),
            "daily": [dict(row) for row in daily],
        }

    def list_snippets(self) -> list[dict[str, Any]]:
        with self._lock, self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, trigger, value, action, created_at, updated_at
                FROM snippets ORDER BY trigger COLLATE NOCASE
                """
            ).fetchall()
            return [dict(row) for row in rows]

    def save_snippet(
        self, trigger: str, value: str, action: str = "insert", snippet_id: Optional[int] = None
    ) -> int:
        trigger = " ".join((trigger or "").strip().split())
        value = (value or "").strip()
        action = action if action in {"insert", "open"} else "insert"
        if not trigger or not value:
            raise ValueError("Snippet trigger and value are required")
        now = _now()
        with self._lock, self._connect() as connection:
            if snippet_id:
                connection.execute(
                    """
                    UPDATE snippets SET trigger = ?, value = ?, action = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (trigger, value, action, now, int(snippet_id)),
                )
                return int(snippet_id)
            cursor = connection.execute(
                """
                INSERT INTO snippets (trigger, value, action, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(trigger) DO UPDATE SET
                    value = excluded.value,
                    action = excluded.action,
                    updated_at = excluded.updated_at
                """,
                (trigger, value, action, now, now),
            )
            return int(cursor.lastrowid)

    def delete_snippet(self, snippet_id: int) -> None:
        with self._lock, self._connect() as connection:
            connection.execute("DELETE FROM snippets WHERE id = ?", (int(snippet_id),))

    def resolve_snippet(self, text: str) -> Optional[dict[str, Any]]:
        trigger = " ".join((text or "").strip().split())
        # Dictation normally adds a final period, while a spoken snippet
        # trigger is stored without punctuation.
        trigger = re.sub(r"[.!?]+$", "", trigger).strip()
        if not trigger:
            return None
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT id, trigger, value, action FROM snippets WHERE trigger = ? COLLATE NOCASE",
                (trigger,),
            ).fetchone()
            return self._row(row)

    def list_notes(self) -> list[dict[str, Any]]:
        with self._lock, self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, title, body, created_at, updated_at
                FROM notes ORDER BY updated_at DESC, id DESC
                """
            ).fetchall()
            return [dict(row) for row in rows]

    def save_note(self, title: str, body: str, note_id: Optional[int] = None) -> int:
        now = _now()
        with self._lock, self._connect() as connection:
            if note_id:
                connection.execute(
                    "UPDATE notes SET title = ?, body = ?, updated_at = ? WHERE id = ?",
                    ((title or "").strip(), body or "", now, int(note_id)),
                )
                return int(note_id)
            cursor = connection.execute(
                """
                INSERT INTO notes (title, body, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """,
                ((title or "").strip(), body or "", now, now),
            )
            return int(cursor.lastrowid)

    def delete_note(self, note_id: int) -> None:
        with self._lock, self._connect() as connection:
            connection.execute("DELETE FROM notes WHERE id = ?", (int(note_id),))
