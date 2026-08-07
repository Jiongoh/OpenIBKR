from __future__ import annotations

import logging
import tempfile
import unittest
from pathlib import Path

from openibkr_helper.logging_config import configure_logging


class LoggingSecurityTests(unittest.TestCase):
    def test_log_is_private_and_does_not_receive_unlogged_token(self) -> None:
        token = "never-log-this-secret-session-token-123456"
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "openibkr.sqlite3"
            log_path = configure_logging(database_path)
            logging.getLogger("openibkr.test").info("safe_event con_id=123")
            for handler in logging.getLogger("openibkr").handlers:
                handler.flush()
            contents = log_path.read_text(encoding="utf-8")
            self.assertIn("safe_event con_id=123", contents)
            self.assertNotIn(token, contents)
            self.assertEqual(log_path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
