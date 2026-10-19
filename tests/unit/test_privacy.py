from tests.unit._helpers import IsolatedTestCase
from cli import privacy

GOOD = '''# privacy.local.toml
usernames = ["osuser", "winuser"]
emails = ["me@example.com"]

[[literal]]
name  = "owner-cloud-uid"
value = "11111111-2222-3333-4444-555555555555"
tier  = "always"
note  = "cloud auth uid"

[[literal]]
name  = "proj-a"
value = "secret-project"
tier  = "public-only"
'''


class TestPrivacy(IsolatedTestCase):
    def write(self, text):
        p = self.tmp / "privacy.local.toml"
        p.write_text(text)
        return p

    def test_good_loads(self):
        p = self.write(GOOD)
        self.assertEqual(privacy.validate_privacy(p), [])
        pr = privacy.load_privacy(p)
        self.assertEqual(pr.usernames, ["osuser", "winuser"])
        self.assertEqual(pr.emails, ["me@example.com"])
        self.assertEqual([l.name for l in pr.literals], ["owner-cloud-uid", "proj-a"])
        self.assertEqual(pr.literals[1].tier, "public-only")
        self.assertEqual(pr.literals[0].note, "cloud auth uid")

    def test_skeleton_loads_and_validates(self):
        p = self.write(privacy.Privacy.skeleton())
        self.assertEqual(privacy.validate_privacy(p), [])
        pr = privacy.load_privacy(p)
        self.assertEqual((pr.usernames, pr.emails, pr.literals), ([], [], []))

    def test_duplicate_name(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('"proj-a"', '"owner-cloud-uid"')))
        self.assertTrue(any("duplicate" in e for e in errs), errs)

    def test_short_value(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('"secret-project"', '"ab"')))
        self.assertTrue(any(">= 4" in e for e in errs), errs)

    def test_missing_name(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('name  = "proj-a"\n', "")))
        self.assertTrue(any("name" in e and "missing" in e for e in errs), errs)

    def test_bad_name_pattern(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('"proj-a"', '"Proj A"')))
        self.assertTrue(any("name" in e for e in errs), errs)

    def test_bad_tier(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('"public-only"', '"sometimes"')))
        self.assertTrue(any("tier" in e for e in errs), errs)

    def test_inline_table_rejected(self):
        text = 'usernames = []\nliteral = [{name = "abc", value = "abcdef", tier = "always"}]\n'
        errs = privacy.validate_privacy(self.write(text))
        self.assertTrue(any("one key per line" in e for e in errs), errs)

    def test_multiline_array_rejected(self):
        errs = privacy.validate_privacy(self.write('usernames = [\n  "a",\n]\n'))
        self.assertTrue(any("one line" in e for e in errs), errs)

    def test_unknown_key_rejected(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('tier  = "always"', 'tire  = "always"')))
        self.assertTrue(any("tire" in e for e in errs), errs)

    def test_errors_never_echo_values(self):
        errs = privacy.validate_privacy(self.write(GOOD.replace('"secret-project"', '"ab"')))
        self.assertFalse(any("secret-project" in e or '"ab"' in e for e in errs), errs)

    def test_missing_file(self):
        self.assertTrue(privacy.validate_privacy(self.tmp / "none")[0].endswith("not found"))
