"""Shared unittest helpers: an isolated HOME / kit dirs per test, never the real ones."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

KIT_ROOT = Path(__file__).resolve().parents[2]
if str(KIT_ROOT) not in sys.path:
    sys.path.insert(0, str(KIT_ROOT))

ISOLATED_VARS = ("HOME", "KIT_CONFIG_HOME", "KIT_STATE_HOME", "KIT_CACHE_HOME", "KIT_DATA_HOME",
                 "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME",
                 "KIT_PROFILE", "KIT_NO_OPEN")


class IsolatedTestCase(unittest.TestCase):
    """Every test gets a throwaway HOME with kit/git/claude config pointed inside it."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="kit-unit-"))
        self._saved = {k: os.environ.get(k) for k in ISOLATED_VARS}
        home = self.tmp / "home"
        home.mkdir()
        gitcfg = self.tmp / "gitconfig"
        gitcfg.write_text("[user]\n\tname = Test User\n\temail = test@example.com\n"
                          "[init]\n\tdefaultBranch = main\n")
        os.environ.update({
            "HOME": str(home),
            "GIT_CONFIG_GLOBAL": str(gitcfg),
            "GIT_CONFIG_NOSYSTEM": "1",
            "KIT_NO_OPEN": "1",
        })
        for k in ("KIT_CONFIG_HOME", "KIT_STATE_HOME", "KIT_CACHE_HOME", "KIT_DATA_HOME",
                  "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "KIT_PROFILE"):
            os.environ.pop(k, None)
        self.home = home

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, repo, *args, check=True):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              check=check).stdout

    def make_repo(self, name="repo", files=None):
        repo = self.tmp / name
        repo.mkdir(parents=True)
        self.git(repo, "init", "-q", "-b", "main")
        for rel, content in (files or {"README.md": "# x\n"}).items():
            p = repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content) if isinstance(content, str) else p.write_bytes(content)
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-q", "-m", "init")
        return repo
