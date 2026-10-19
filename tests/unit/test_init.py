from tests.unit._helpers import IsolatedTestCase
from cli import init_cmd


class TestGitignoreBlock(IsolatedTestCase):
    def test_append_then_idempotent(self):
        p = self.tmp / ".gitignore"
        p.write_text("node_modules/\n")
        self.assertTrue(init_cmd.ensure_gitignore_block(p))
        first = p.read_text()
        self.assertTrue(first.startswith("node_modules/\n"))
        self.assertEqual(first.count("# >>> kit v5"), 1)
        self.assertFalse(init_cmd.ensure_gitignore_block(p))
        self.assertEqual(p.read_text(), first)

    def test_stale_block_refreshed_in_place(self):
        p = self.tmp / ".gitignore"
        p.write_text("a\n# >>> kit v5 (old) >>>\n.claude/\n# <<< kit v5 <<<\nb\n")
        self.assertTrue(init_cmd.ensure_gitignore_block(p))
        t = p.read_text()
        self.assertTrue(t.startswith("a\n# >>> kit v5"))
        self.assertTrue(t.endswith("# <<< kit v5 <<<\nb\n"))
        self.assertIn("docs/superpowers/plans/", t)

    def test_dry_run_does_not_write(self):
        p = self.tmp / ".gitignore"
        p.write_text("x\n")
        self.assertTrue(init_cmd.ensure_gitignore_block(p, dry_run=True))
        self.assertEqual(p.read_text(), "x\n")

    def test_missing_file_created(self):
        p = self.tmp / ".gitignore"
        self.assertTrue(init_cmd.ensure_gitignore_block(p))
        self.assertTrue(p.read_text().startswith("# >>> kit v5"))
