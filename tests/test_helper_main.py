from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from openibkr_helper.main import _configured_parent_pid, _process_exists, _watch_parent


class _ServerStub:
    should_exit = False


class HelperParentWatchdogTests(unittest.IsolatedAsyncioTestCase):
    def test_parent_pid_configuration_is_optional_and_validated(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(_configured_parent_pid())
        with patch.dict(os.environ, {"OPENIBKR_PARENT_PID": "12345"}, clear=True):
            self.assertEqual(_configured_parent_pid(), 12345)
        for invalid in ("not-a-pid", "0", "1", "-2"):
            with (
                self.subTest(invalid=invalid),
                patch.dict(os.environ, {"OPENIBKR_PARENT_PID": invalid}, clear=True),
                self.assertRaises(RuntimeError),
            ):
                _configured_parent_pid()

    def test_missing_process_is_detected(self) -> None:
        self.assertFalse(_process_exists(2_147_483_647))

    async def test_watchdog_requests_shutdown_when_parent_disappears(self) -> None:
        server = _ServerStub()
        with (
            patch("openibkr_helper.main._process_exists", return_value=False),
            patch("openibkr_helper.main.asyncio.sleep", return_value=None),
        ):
            await _watch_parent(server, 12345)
        self.assertTrue(server.should_exit)


if __name__ == "__main__":
    unittest.main()
