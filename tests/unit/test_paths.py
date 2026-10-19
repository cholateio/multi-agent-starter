import os
from pathlib import Path

from tests.unit._helpers import KIT_ROOT, IsolatedTestCase
from cli import paths


class TestPaths(IsolatedTestCase):
    def test_config_dir_env_override(self):
        os.environ["KIT_CONFIG_HOME"] = "/x"
        self.assertEqual(paths.config_dir(), Path("/x"))

    def test_config_dir_default(self):
        self.assertEqual(paths.config_dir(), self.home / ".config" / "kit")

    def test_state_cache_data_defaults_and_overrides(self):
        self.assertEqual(paths.state_dir(), self.home / ".local" / "state" / "kit")
        self.assertEqual(paths.cache_dir(), self.home / ".cache" / "kit")
        self.assertEqual(paths.data_dir(), self.home / ".local" / "share" / "kit")
        os.environ["KIT_STATE_HOME"] = "/s"
        os.environ["KIT_CACHE_HOME"] = "/c"
        self.assertEqual(paths.state_dir(), Path("/s"))
        self.assertEqual(paths.cache_dir(), Path("/c"))

    def test_kit_root_is_parent_of_bin(self):
        self.assertEqual(paths.kit_root(), KIT_ROOT)
        self.assertTrue((paths.kit_root() / "bin" / "kit").is_file())

    def test_claude_dir_honors_claude_config_dir(self):
        self.assertEqual(paths.claude_dir(), self.home / ".claude")
        os.environ["CLAUDE_CONFIG_DIR"] = "/cc"
        self.assertEqual(paths.claude_dir(), Path("/cc"))

    def test_load_config_missing_is_empty(self):
        self.assertEqual(paths.load_config(), {})

    def test_load_config_reads_toml(self):
        os.environ["KIT_CONFIG_HOME"] = str(self.tmp / "cfg")
        (self.tmp / "cfg").mkdir()
        (self.tmp / "cfg" / "config.toml").write_text('kit_root = "/k"\n[audit]\nexclude = ["a-*"]\n')
        cfg = paths.load_config()
        self.assertEqual(cfg["kit_root"], "/k")
        self.assertEqual(cfg["audit"]["exclude"], ["a-*"])
