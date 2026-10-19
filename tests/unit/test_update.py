import contextlib
import io
import json
import os
from types import SimpleNamespace

from tests.unit._helpers import KIT_ROOT, IsolatedTestCase
from cli import update_cmd


class TestUpdate(IsolatedTestCase):
    def write_km(self, entry):
        d = self.home / ".claude" / "plugins"
        d.mkdir(parents=True)
        (d / "known_marketplaces.json").write_text(json.dumps({"multi-agent-kit": entry} if entry else {}))
        # installed_plugins.json points at a CACHE copy even for directory marketplaces (spike 0.1)
        (d / "installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"kit@multi-agent-kit": [
            {"scope": "user", "installPath": str(self.home / ".claude/plugins/cache/multi-agent-kit/kit/5.0.0")}]}}))

    def test_directory_marketplace_at_kit_root_is_local(self):
        self.write_km({"source": {"source": "directory", "path": str(KIT_ROOT)}})
        self.assertEqual(update_cmd.decide({"kit_root": str(KIT_ROOT)}), ("local", KIT_ROOT))

    def test_github_marketplace(self):
        self.write_km({"source": {"source": "github", "repo": "acme/multi-agent-starter"}})
        self.assertEqual(update_cmd.decide({"kit_root": str(KIT_ROOT)})[0], "github")

    def test_directory_elsewhere_is_not_this_checkout(self):
        self.write_km({"source": {"source": "directory", "path": str(self.tmp / "other")}})
        mode, why = update_cmd.decide({"kit_root": str(KIT_ROOT)})
        self.assertIsNone(mode)
        self.assertIn("other", why)

    def test_not_installed(self):
        self.write_km(None)
        mode, why = update_cmd.decide({})
        self.assertIsNone(mode)
        self.assertIn("kit setup", why)

    def run_dry(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = update_cmd.run(SimpleNamespace(dry_run=True))
        return rc, buf.getvalue()

    def test_dry_run_local(self):
        self.write_km({"source": {"source": "directory", "path": str(KIT_ROOT)}})
        rc, out = self.run_dry()
        self.assertEqual(rc, 0)
        self.assertIn(f"WOULD RUN: git -C {KIT_ROOT} pull --ff-only", out)
        self.assertIn("/reload-plugins", out)

    def test_dry_run_github(self):
        self.write_km({"source": {"source": "github", "repo": "acme/multi-agent-starter"}})
        rc, out = self.run_dry()
        self.assertIn("WOULD RUN: claude plugin update kit@multi-agent-kit", out)

    def test_not_installed_exit_1(self):
        self.write_km(None)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(update_cmd.run(SimpleNamespace(dry_run=True)), 1)
