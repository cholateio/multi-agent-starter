import contextlib
import io
import subprocess

from tests.unit._helpers import KIT_ROOT, IsolatedTestCase
from cli.main import main, SUBCOMMANDS


class TestMain(IsolatedTestCase):
    def test_version(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["--version"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "kit " + (KIT_ROOT / "VERSION").read_text().strip())

    def test_unknown_subcommand_exits_2(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(["frobnicate"]), 2)

    def test_no_args_prints_help_exit_2(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main([]), 2)

    def test_help_lists_seven_subcommands(self):
        self.assertEqual(sorted(SUBCOMMANDS),
                         sorted(["setup", "doctor", "init", "migrate", "audit", "guard", "update"]))
        out = subprocess.run([str(KIT_ROOT / "bin" / "kit"), "--help"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        for s in SUBCOMMANDS:
            self.assertIn(s, out.stdout)

    def test_bin_kit_version_runs_from_anywhere(self):
        out = subprocess.run([str(KIT_ROOT / "bin" / "kit"), "--version"], capture_output=True,
                             text=True, cwd=str(self.tmp))
        self.assertEqual(out.returncode, 0)
        self.assertTrue(out.stdout.startswith("kit 5."))
