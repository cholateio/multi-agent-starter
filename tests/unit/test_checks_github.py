"""kit audit GitHub checks (Task 3.8b) against recorded fixtures (fake owner acme)."""
import os

from tests.unit._helpers import KIT_ROOT, IsolatedTestCase
from cli.audit import checks_github as cg
from cli.audit.scan import AuditCtx, Target
from cli.kittoml import KitToml

FIX = KIT_ROOT / "tests" / "fixtures" / "audit" / "gh"


def sev(findings):
    return {f.check: f.severity for f in findings}


class TestGithubChecks(IsolatedTestCase):
    def setUp(self):
        super().setUp()
        self.gh = cg.GhClient(FIX)

    def run_gh(self, name, kittoml=None, visibility="public", path=None):
        t = Target(name, path, f"acme/{name}")
        ctx = AuditCtx(privacy=None, kittoml=kittoml, visibility=visibility)
        return cg.run_github_checks(t, ctx, self.gh)

    def test_fixture_client(self):
        self.assertEqual(self.gh.call("repos/acme/proj-a/vulnerability-alerts")[0], 404)
        self.assertEqual(self.gh.call("repos/acme/proj-b/vulnerability-alerts")[0], 204)
        self.assertEqual(self.gh.call("repos/acme/nope")[0], None)
        self.assertEqual(self.gh.login(), "acme")
        self.assertEqual([r["name"] for r in self.gh.repo_list("acme")][:2], ["proj-a", "proj-b"])

    def test_all_bad(self):
        f = self.run_gh("proj-a", kittoml=KitToml(visibility="private"))
        self.assertEqual(sev(f), {"A6": "HIGH", "A7": "HIGH", "A8": "MEDIUM", "A9": "HIGH", "A14": "LOW",
                                  "A18": "LOW"})

    def test_all_good(self):
        f = self.run_gh("proj-b", kittoml=KitToml(visibility="public"))
        self.assertEqual(f, [], f)

    def test_private_repo_skips_public_only_checks(self):
        f = self.run_gh("proj-remote", visibility="private")
        self.assertEqual(sev(f), {})

    def test_no_kit_toml_no_a6(self):
        self.assertNotIn("A6", sev(self.run_gh("proj-b")))

    def test_v4_layout_without_kit_toml_is_a6_high(self):
        repo = self.make_repo("proj-b", {".claude/kit-version": "v4.10.0\n"})
        f = self.run_gh("proj-b", path=repo)
        self.assertEqual(sev(f).get("A6"), "HIGH")

    def test_gh_unavailable_everything_unknown(self):
        saved = os.environ["PATH"]
        os.environ["PATH"] = str(self.tmp)            # no gh anywhere
        try:
            gh = cg.GhClient(None)
            t = Target("proj-a", None, "acme/proj-a")
            f = cg.run_github_checks(t, AuditCtx(privacy=None, kittoml=KitToml(), visibility="public"), gh)
        finally:
            os.environ["PATH"] = saved
        self.assertTrue(f)
        self.assertEqual({x.severity for x in f}, {"UNKNOWN"})
        self.assertEqual({x.check for x in f}, {"A6", "A7", "A8", "A9", "A14", "A18"})

    def test_no_remote_is_unknown(self):
        t = Target("local-only", None, None)
        f = cg.run_github_checks(t, AuditCtx(privacy=None, kittoml=KitToml(), visibility="public"), self.gh)
        self.assertEqual({x.severity for x in f}, {"UNKNOWN"})
