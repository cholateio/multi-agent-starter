import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "anonymize", Path(__file__).resolve().parents[1] / "tools" / "anonymize.py")
anon = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(anon)

TABLE = '''
[[literal]]
name = "a"
value = "zebra-app"
tier = "public-only"
alias = "proj-a"

[[literal]]
name = "b"
value = "zebra-app-content"
tier = "public-only"
note = "alias=proj-b"

[[literal]]
name = "c"
value = "keepme-always"
tier = "always"
alias = "nope"
'''


class AnonymizeTest(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.t = self.d / "t.toml"
        self.t.write_text(TABLE)

    def test_replace_longest_first_whole_word_case_insensitive(self):
        rules = anon.compile_rules(anon.load_table(self.t))
        out, n = anon.process("Zebra-App and zebra-app-content; xzebra-app, zebra-apps, keepme-always", rules)
        self.assertEqual(out, "proj-a and proj-b; xzebra-app, zebra-apps, keepme-always")
        self.assertEqual(n, 2)

    def test_check_does_not_write_and_exits_1(self):
        f = self.d / "f.md"
        f.write_text("see zebra-app")
        run = lambda *a: anon.main([*a, "--table", str(self.t), str(f)])  # noqa: E731
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(run("--check"), 1)
            self.assertEqual(f.read_text(), "see zebra-app")
            self.assertEqual(run(), 0)
            self.assertEqual(f.read_text(), "see proj-a")
            self.assertEqual(run("--check"), 0)
        self.assertNotIn("zebra", out.getvalue())  # output never echoes the names


if __name__ == "__main__":
    unittest.main()
