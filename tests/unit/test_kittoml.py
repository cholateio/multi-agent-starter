from tests.unit._helpers import IsolatedTestCase
from cli import kittoml

GOOD = '''# kit.toml
kit = 5
visibility = "public"
license = "MIT"
readme_lang = "en"
protected = [              # header comment is fine
  # one entry per line
  "supabase/migrations/*",
  "src/legacy/",
]

[privacy]
allow_paths = ["docs/media/*"]
allow_literals = ["owner-cloud-uid"]
'''


class TestKitToml(IsolatedTestCase):
    def write(self, text):
        p = self.tmp / "kit.toml"
        p.write_text(text)
        return p

    def test_good_file_parses_and_validates(self):
        p = self.write(GOOD)
        self.assertEqual(kittoml.validate_kit_toml(p), [])
        k = kittoml.parse_kit_toml(p)
        self.assertEqual((k.kit, k.visibility, k.license, k.readme_lang), (5, "public", "MIT", "en"))
        self.assertEqual(k.protected, ["supabase/migrations/*", "src/legacy/"])
        self.assertEqual(k.allow_paths, ["docs/media/*"])
        self.assertEqual(k.allow_literals, ["owner-cloud-uid"])
        self.assertEqual(k.path, p)

    def test_defaults_for_missing_keys(self):
        k = kittoml.parse_kit_toml(self.write("kit = 5\n"))
        self.assertEqual((k.visibility, k.license, k.readme_lang), ("public", "none", "en"))
        self.assertEqual((k.protected, k.allow_paths, k.allow_literals), ([], [], []))

    def test_inline_comment_on_entry_line(self):
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace('"src/legacy/",', '"src/legacy/", # old')))
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("inline comment", errs[0])
        self.assertTrue(errs[0].startswith("kit.toml:"))

    def test_two_entries_on_one_line(self):
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace('"src/legacy/",', '"src/legacy/", "b/",')))
        self.assertTrue(any("one entry per line" in e for e in errs), errs)

    def test_allow_literals_must_be_names(self):
        for bad in ('["b2a3-looks-like-a-value-1234567890-abcdef"]', '["x@y.z"]', '["UPPER"]', '["ab"]'):
            errs = kittoml.validate_kit_toml(self.write(GOOD.replace('["owner-cloud-uid"]', bad)))
            self.assertTrue(any("allow_literals" in e for e in errs), (bad, errs))

    def test_visibility_case_sensitive(self):
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace('"public"', '"Public"')))
        self.assertTrue(any("visibility" in e for e in errs), errs)

    def test_kit_must_be_5(self):
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace("kit = 5", "kit = 4")))
        self.assertTrue(any("kit = 5" in e for e in errs), errs)
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace("kit = 5\n", "")))
        self.assertTrue(any("kit = 5" in e for e in errs), errs)

    def test_license_and_lang_enums(self):
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace('"MIT"', '"GPL"')))
        self.assertTrue(any("license" in e for e in errs), errs)
        errs = kittoml.validate_kit_toml(self.write(GOOD.replace('readme_lang = "en"', 'readme_lang = "fr"')))
        self.assertTrue(any("readme_lang" in e for e in errs), errs)

    def test_scalar_protected_is_an_error(self):
        # Phase-2 deferred minor: the bash hook silently ignores a scalar; doctor must not
        errs = kittoml.validate_kit_toml(self.write('kit = 5\nprotected = "src/"\n'))
        self.assertTrue(any("protected" in e and "array" in e for e in errs), errs)

    def test_toml_syntax_error_reported_not_raised(self):
        errs = kittoml.validate_kit_toml(self.write('kit = 5\nprotected = [\n  src/,\n]\n'))
        self.assertEqual(len(errs), 1)
        self.assertIn("kit.toml:", errs[0])

    def test_missing_file(self):
        errs = kittoml.validate_kit_toml(self.tmp / "nope.toml")
        self.assertTrue(errs and "not found" in errs[0])

    def test_render_roundtrip_validates(self):
        text = kittoml.render_kit_toml("private", "none", "zh-TW", ["# legacy", "src/legacy/*"])
        p = self.write(text)
        self.assertEqual(kittoml.validate_kit_toml(p), [])
        k = kittoml.parse_kit_toml(p)
        self.assertEqual((k.visibility, k.license, k.readme_lang), ("private", "none", "zh-TW"))
        self.assertEqual(k.protected, ["src/legacy/*"])
        self.assertIn("  # legacy\n", text)

    def test_render_matches_bash_parser(self):
        import subprocess
        from tests.unit._helpers import KIT_ROOT
        text = kittoml.render_kit_toml("public", "MIT", "en", ["# c", "a/*", "b/"])
        self.write(text)
        out = subprocess.run(["bash", "-c", 'source "$1/plugin/hooks/lib.sh"; kit_toml_protected "$2"', "_",
                              str(KIT_ROOT), str(self.tmp)], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.split(), ["a/*", "b/"])
