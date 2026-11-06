import contextlib
import io
import unittest
from unittest import mock

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import sync_upstream


class MainTests(unittest.TestCase):
    def test_returns_zero_when_all_sources_sync(self):
        sources = [{"name": "one"}, {"name": "two"}]
        with mock.patch.object(sync_upstream, "load_sources", return_value=sources), \
             mock.patch.object(sync_upstream, "sync") as sync:
            self.assertEqual(sync_upstream.main(), 0)
        self.assertEqual(sync.call_count, 2)

    def test_returns_nonzero_when_a_source_fails(self):
        sources = [{"name": "broken"}]
        stderr = io.StringIO()
        with mock.patch.object(sync_upstream, "load_sources", return_value=sources), \
             mock.patch.object(sync_upstream, "sync", side_effect=RuntimeError("upstream unavailable")), \
             contextlib.redirect_stderr(stderr):
            self.assertEqual(sync_upstream.main(), 1)
        self.assertIn("broken", stderr.getvalue())
        self.assertIn("upstream unavailable", stderr.getvalue())

    def test_attempts_remaining_sources_after_one_failure(self):
        sources = [{"name": "broken"}, {"name": "healthy"}]
        calls = []

        def fake_sync(source):
            calls.append(source["name"])
            if source["name"] == "broken":
                raise RuntimeError("upstream unavailable")

        with mock.patch.object(sync_upstream, "load_sources", return_value=sources), \
             mock.patch.object(sync_upstream, "sync", side_effect=fake_sync), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(sync_upstream.main(), 1)

        self.assertEqual(calls, ["broken", "healthy"])


if __name__ == "__main__":
    unittest.main()
