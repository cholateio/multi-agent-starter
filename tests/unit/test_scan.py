from tests.unit._helpers import KIT_ROOT, IsolatedTestCase
from cli.audit import scan
from cli.audit.checks_github import GhClient

FIX = KIT_ROOT / "tests" / "fixtures" / "audit" / "gh"


class TestScan(IsolatedTestCase):
    def setUp(self):
        super().setUp()
        self.root = self.tmp / "fleet"
        self.root.mkdir()
        for n in ("proj-a", "proj-b", "sideproj"):
            r = self.make_repo(f"fleet/{n}")
            self.git(r, "remote", "add", "origin", f"git@github.com:acme/{n}.git")
        (self.root / "not-a-repo").mkdir()

    def names(self, targets):
        return [t.name for t in targets]

    def test_local_only(self):
        t = scan.scan_targets({"audit": {"root": str(self.root)}})
        self.assertEqual(self.names(t), ["proj-a", "proj-b", "sideproj"])
        self.assertEqual(t[0].remote, "acme/proj-a")

    def test_gh_list_adds_remote_only_and_skips_archived(self):
        t = scan.scan_targets({"audit": {"root": str(self.root)}}, gh=GhClient(FIX), owner="acme")
        self.assertEqual(self.names(t), ["proj-a", "proj-b", "proj-remote", "sideproj"])
        rem = next(x for x in t if x.name == "proj-remote")
        self.assertIsNone(rem.path)
        self.assertEqual(rem.gh_visibility, "private")

    def test_exclude_globs_from_local_config(self):
        t = scan.scan_targets({"audit": {"root": str(self.root), "exclude": ["side*", "proj-remote"]}},
                              gh=GhClient(FIX), owner="acme")
        self.assertEqual(self.names(t), ["proj-a", "proj-b"])

    def test_name_filter(self):
        t = scan.scan_targets({"audit": {"root": str(self.root)}}, names=["proj-b"])
        self.assertEqual(self.names(t), ["proj-b"])

    def test_root_tilde_uses_isolated_home(self):
        (self.home / "x").mkdir()
        self.make_repo("home/x/r")
        self.assertEqual(self.names(scan.scan_targets({"audit": {"root": "~/x"}})), ["r"])
