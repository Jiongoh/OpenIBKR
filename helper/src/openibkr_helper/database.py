"""Single-writer SQLite persistence for settings, contracts and watchlist."""

from __future__ import annotations

import os
import sqlite3
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .models import AppSnapshot, Instrument

SCHEMA_VERSION = 3


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._connection: sqlite3.Connection | None = None
        self._lock = threading.RLock()

    @property
    def schema_version(self) -> int:
        connection = self._require_connection()
        row = connection.execute("PRAGMA user_version").fetchone()
        return int(row[0])

    def open(self) -> None:
        if self._connection is not None:
            return
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except PermissionError:
            pass
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = NORMAL")
        self._connection = connection
        self._migrate()
        try:
            os.chmod(self.path, 0o600)
        except PermissionError:
            pass

    def close(self) -> None:
        with self._lock:
            if self._connection is not None:
                self._connection.close()
                self._connection = None

    def _migrate(self) -> None:
        connection = self._require_connection()
        version = self.schema_version
        if version > SCHEMA_VERSION:
            raise RuntimeError(
                f"Database schema {version} is newer than supported {SCHEMA_VERSION}"
            )
        if version == 0:
            with connection:
                connection.executescript(
                    """
                    CREATE TABLE contracts (
                        con_id INTEGER PRIMARY KEY,
                        symbol TEXT NOT NULL,
                        sec_type TEXT NOT NULL,
                        exchange TEXT NOT NULL,
                        currency TEXT NOT NULL,
                        primary_exchange TEXT,
                        local_symbol TEXT,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );

                    CREATE TABLE watchlist (
                        con_id INTEGER PRIMARY KEY REFERENCES contracts(con_id)
                            ON DELETE CASCADE,
                        sort_order INTEGER NOT NULL,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );

                    CREATE TABLE settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );

                    CREATE INDEX watchlist_sort_order_idx
                        ON watchlist(sort_order, con_id);
                    PRAGMA user_version = 1;
                    """
                )
            version = 1
        if version == 1:
            with connection:
                connection.executescript(
                    """
                    CREATE TABLE latest_snapshots (
                        key TEXT PRIMARY KEY,
                        payload_json TEXT NOT NULL,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );
                    PRAGMA user_version = 2;
                    """
                )
            version = 2
        if version == 2:
            with connection:
                connection.executescript(
                    """
                    CREATE TABLE pnl_minute_samples (
                        bucket_at TEXT PRIMARY KEY,
                        daily TEXT,
                        unrealized TEXT,
                        realized TEXT,
                        currency TEXT
                    );
                    PRAGMA user_version = 3;
                    """
                )

    def upsert_contract(self, instrument: Instrument) -> None:
        connection = self._require_connection()
        with self._lock, connection:
            connection.execute(
                """
                INSERT INTO contracts (
                    con_id, symbol, sec_type, exchange, currency,
                    primary_exchange, local_symbol
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(con_id) DO UPDATE SET
                    symbol = excluded.symbol,
                    sec_type = excluded.sec_type,
                    exchange = excluded.exchange,
                    currency = excluded.currency,
                    primary_exchange = excluded.primary_exchange,
                    local_symbol = excluded.local_symbol,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (
                    instrument.con_id,
                    instrument.symbol,
                    instrument.sec_type,
                    instrument.exchange,
                    instrument.currency,
                    instrument.primary_exchange,
                    instrument.local_symbol,
                ),
            )

    def add_to_watchlist(self, instrument: Instrument) -> bool:
        self.upsert_contract(instrument)
        connection = self._require_connection()
        with self._lock, connection:
            exists = connection.execute(
                "SELECT 1 FROM watchlist WHERE con_id = ?", (instrument.con_id,)
            ).fetchone()
            if exists is not None:
                return False
            next_order = connection.execute(
                "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM watchlist"
            ).fetchone()[0]
            connection.execute(
                "INSERT INTO watchlist (con_id, sort_order) VALUES (?, ?)",
                (instrument.con_id, next_order),
            )
            return True

    def remove_from_watchlist(self, con_id: int) -> bool:
        connection = self._require_connection()
        with self._lock, connection:
            cursor = connection.execute("DELETE FROM watchlist WHERE con_id = ?", (con_id,))
            return cursor.rowcount > 0

    def list_watchlist(self) -> list[Instrument]:
        connection = self._require_connection()
        with self._lock:
            rows = connection.execute(
                """
                SELECT c.*
                FROM watchlist w
                JOIN contracts c ON c.con_id = w.con_id
                ORDER BY w.sort_order, w.con_id
                """
            ).fetchall()
        return [
            Instrument(
                con_id=row["con_id"],
                symbol=row["symbol"],
                sec_type=row["sec_type"],
                exchange=row["exchange"],
                currency=row["currency"],
                primary_exchange=row["primary_exchange"],
                local_symbol=row["local_symbol"],
            )
            for row in rows
        ]

    def watchlist_count(self) -> int:
        connection = self._require_connection()
        with self._lock:
            return int(connection.execute("SELECT COUNT(*) FROM watchlist").fetchone()[0])

    def save_public_snapshot(self, snapshot: AppSnapshot) -> None:
        connection = self._require_connection()
        payload = snapshot.model_dump_json()
        with self._lock, connection:
            connection.execute(
                """
                INSERT INTO latest_snapshots (key, payload_json)
                VALUES ('app', ?)
                ON CONFLICT(key) DO UPDATE SET
                    payload_json = excluded.payload_json,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (payload,),
            )

    def load_public_snapshot(self) -> AppSnapshot | None:
        connection = self._require_connection()
        with self._lock:
            row = connection.execute(
                "SELECT payload_json FROM latest_snapshots WHERE key = 'app'"
            ).fetchone()
        if row is None:
            return None
        return AppSnapshot.model_validate_json(row["payload_json"])

    def save_pnl_minute(self, snapshot: AppSnapshot, *, retention_hours: int = 24) -> bool:
        received_at = snapshot.pnl.received_at
        if received_at is None or snapshot.pnl.stale:
            return False
        bucket = received_at.replace(second=0, microsecond=0)
        cutoff = bucket - timedelta(hours=retention_hours)
        connection = self._require_connection()
        with self._lock, connection:
            cursor = connection.execute(
                """
                INSERT OR IGNORE INTO pnl_minute_samples (
                    bucket_at, daily, unrealized, realized, currency
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    bucket.isoformat(),
                    str(snapshot.pnl.daily) if snapshot.pnl.daily is not None else None,
                    str(snapshot.pnl.unrealized) if snapshot.pnl.unrealized is not None else None,
                    str(snapshot.pnl.realized) if snapshot.pnl.realized is not None else None,
                    snapshot.account.currency,
                ),
            )
            connection.execute(
                "DELETE FROM pnl_minute_samples WHERE bucket_at < ?",
                (cutoff.isoformat(),),
            )
            return cursor.rowcount > 0

    def prune_pnl_minute(
        self,
        *,
        retention_hours: int = 24,
        now: datetime | None = None,
    ) -> int:
        cutoff = (now or datetime.now(UTC)) - timedelta(hours=retention_hours)
        connection = self._require_connection()
        with self._lock, connection:
            cursor = connection.execute(
                "DELETE FROM pnl_minute_samples WHERE bucket_at < ?",
                (cutoff.isoformat(),),
            )
            return cursor.rowcount

    def pnl_minute_count(self) -> int:
        connection = self._require_connection()
        with self._lock:
            return int(connection.execute("SELECT COUNT(*) FROM pnl_minute_samples").fetchone()[0])

    def _require_connection(self) -> sqlite3.Connection:
        if self._connection is None:
            raise RuntimeError("Database is not open")
        return self._connection
