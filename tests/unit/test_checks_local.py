"""kit audit local checks (Task 3.8a). Fixture repos are built in a temp dir;
all literals are fake (11111111-2222-..., /home/testuser/, proj-a)."""
import json
import os
import shutil
import unittest
from pathlib import Path

from tests.unit._helpers import IsolatedTestCase
from cli.audit import checks_local as cl
from cli.audit.report import Finding, redact
from cli.audit.scan import Target, AuditCtx
from cli.kittoml import KitToml
from cli.privacy import Literal, Privacy

UID = "11111111-2222-3333-4444-555555555555"
PRIV = Privacy(usernames=["testuser"], emails=[], literals=[Literal("t-uid", UID, "always", "fake uid")])


def ctx(**kw):
    base = dict(privacy=PRIV, kittoml=None, visibility="public", tools={}, offline=True, gh_repo=None,
                project_status=None)
    base.update(kw)
    return AuditCtx(**base)


def checks(findings, check):
    return [f for f in findings if f.check == check]


BAD_FILES = {
    "README.md": "# proj-a — my private tool\n\n這是私人 repo，給自己用。\n",
    ".claude/x": "x\n",
    "notes.txt": "see /home/testuser/x for data\n",
    ".github/workflows/w.yml": "on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n",
    "LICENSE": "",
    ".gitignore": "node_modules/\n",
    "src/a.js": f"const OWNER = '{UID}';\n",
}

CLEAN_FILES = {
    "README.md": "# proj-b\n\nA small tool.\n\n## Install\n\nRun it.\n\n## License\n\nMIT\n",
    "LICENSE": "MIT License\n\nCopyright (c) 2026 Test\n",
    ".gitignore": "# >>> kit v5 (managed block — edit outside the markers) >>>\n.claude/\n# <<< kit v5 <<<\n",
    ".github/workflows/w.yml": "on: push\npermissions:\n  contents: read\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v4.1.0\n",
    "src/a.js": "export const x = 1;\n",
}


class TestLocalChecks(IsolatedTestCase):
    def run_local(self, repo, c):
        return cl.run_local_checks(Target(repo.name, repo, None), c)

    def test_bad_fixture_hits(self):
        repo = self.make_repo("proj-a", BAD_FILES)
        f = self.run_local(repo, ctx())
        a4 = checks(f, "A4")
        self.assertEqual(len(a4), 1)
        self.assertEqual((a4[0].severity, a4[0].path), ("HIGH", ".claude/x"))
        a15 = checks(f, "A15")
        self.assertTrue(any("H1" in x.snippet for x in a15), a15)
        self.assertTrue(any(x.severity == "MEDIUM" and "marker" in x.snippet for x in a15), a15)
        a5 = checks(f, "A5")
        self.assertTrue(any(x.path == "notes.txt" and x.line == 1 for x in a5), a5)
        self.assertNotIn("testuser", " ".join(x.snippet for x in a5))   # redacted
        a10 = checks(f, "A10")
        self.assertEqual([(x.severity, x.path) for x in a10], [("MEDIUM", ".github/workflows/w.yml")])
        self.assertEqual(len(checks(f, "A11")), 1)
        self.assertEqual([x.severity for x in checks(f, "A13")], ["MEDIUM"])
        self.assertEqual(len(checks(f, "A17")), 1)
        a2 = checks(f, "A2")
        self.assertEqual([(x.severity, x.path, x.line) for x in a2], [("HIGH", "src/a.js", 1)])
        self.assertIn("<t-uid>", a2[0].snippet)
        self.assertNotIn(UID, json.dumps([x.__dict__ for x in f]))     # value never in output

    def test_allow_literal_turns_a2_into_a2x(self):
        repo = self.make_repo("proj-a", BAD_FILES)
        kt = KitToml(allow_literals=["t-uid"])
        f = self.run_local(repo, ctx(kittoml=kt))
        self.assertEqual(checks(f, "A2"), [])
        a2x = checks(f, "A2x")
        self.assertEqual([(x.severity, x.snippet) for x in a2x],
                         [("INFO", "literal t-uid allowed by kit.toml [privacy]")])

    def test_history_only_literal_is_a3(self):
        repo = self.make_repo("proj-a", BAD_FILES)
        (repo / "src/a.js").write_text("export const x = 1;\n")
        self.git(repo, "commit", "-qam", "drop literal")
        f = self.run_local(repo, ctx())
        self.assertEqual(checks(f, "A2"), [])
        a3 = checks(f, "A3")
        self.assertEqual(len(a3), 1)
        self.assertEqual(a3[0].severity, "MEDIUM")
        sha7 = self.git(repo, "rev-parse", "--short=7", "HEAD~1").strip()
        self.assertIn(sha7, a3[0].snippet)
        self.assertNotIn(UID, a3[0].snippet)
        f2 = self.run_local(repo, ctx(kittoml=KitToml(allow_literals=["t-uid"])))
        self.assertEqual(checks(f2, "A3"), [])
        self.assertEqual(len(checks(f2, "A2x")), 1)

    def test_private_visibility_severities(self):
        repo = self.make_repo("proj-a", BAD_FILES)
        f = self.run_local(repo, ctx(visibility="private"))
        self.assertEqual([x.severity for x in checks(f, "A2")], ["MEDIUM"])
        self.assertEqual([x.severity for x in checks(f, "A4")], ["MEDIUM"])
        self.assertEqual(checks(f, "A15"), [])          # README checks are public-only
        self.assertEqual(checks(f, "A13"), [])

    def test_public_only_literal_ignored_in_private(self):
        p = Privacy(literals=[Literal("proj-x", "secret-project", "public-only")])
        repo = self.make_repo("proj-a", {"a.txt": "uses secret-project here\n"})
        self.assertEqual(checks(self.run_local(repo, ctx(privacy=p, visibility="private")), "A2"), [])
        self.assertEqual(len(checks(self.run_local(repo, ctx(privacy=p)), "A2")), 1)

    def test_clean_fixture_zero_findings(self):
        repo = self.make_repo("proj-b", CLEAN_FILES)
        f = [x for x in self.run_local(repo, ctx()) if x.severity != "UNKNOWN"]
        self.assertEqual(f, [], f)
        unknown = {x.check for x in self.run_local(repo, ctx()) if x.severity == "UNKNOWN"}
        self.assertEqual(unknown, {"A1"})              # gitleaks not provided; no lockfile → no A12

    def test_a16_local_hookspath(self):
        repo = self.make_repo("proj-b", CLEAN_FILES)
        self.git(repo, "config", "--local", "core.hooksPath", ".husky")
        self.assertEqual([x.severity for x in checks(self.run_local(repo, ctx()), "A16")], ["HIGH"])

    def test_a10_write_permission_is_high(self):
        files = dict(CLEAN_FILES)
        files[".github/workflows/w.yml"] = ("on: push\npermissions:\n  contents: write\njobs:\n  b:\n"
                                            "    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n")
        repo = self.make_repo("proj-b", files)
        f = self.run_local(repo, ctx())
        self.assertEqual([x.severity for x in checks(f, "A10")], ["HIGH"])
        self.assertEqual(checks(f, "A11"), [])

    def test_a5_email_rules(self):
        repo = self.make_repo("proj-b", dict(CLEAN_FILES, **{"c.txt": "a real.person@corp-mail.dev\n"
                                                             "x@users.noreply.github.com\nme@example.com\n"
                                                             "git@github.com:o/r.git\n"
                                                             "ok person@corp-mail.dev kit-privacy: allow\n"}))
        a5 = checks(self.run_local(repo, ctx()), "A5")
        self.assertEqual([(x.path, x.line) for x in a5], [("c.txt", 1)])

    def test_allow_paths_skip_a5(self):
        repo = self.make_repo("proj-b", dict(CLEAN_FILES, **{"docs/media/x.txt": "/home/testuser/y\n"}))
        f = self.run_local(repo, ctx(kittoml=KitToml(allow_paths=["docs/media/*"])))
        self.assertEqual(checks(f, "A5"), [])

    def test_a1_parses_gitleaks_report(self):
        fake = self.tmp / "fake-gitleaks"
        fake.write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = "--report-path" ] && out="$2"; shift; done\n'
                        'printf \'[{"RuleID":"github-pat","File":"cfg/x.env","StartLine":3,"Commit":"abcdef1234567",'
                        '"Secret":"REDACTED","Match":"token=REDACTED"}]\' > "$out"\nexit 1\n')
        fake.chmod(0o755)
        repo = self.make_repo("proj-b", CLEAN_FILES)
        f = checks(self.run_local(repo, ctx(tools={"gitleaks": fake})), "A1")
        self.assertEqual([(x.severity, x.path, x.line) for x in f], [("CRITICAL", "cfg/x.env", 3)])
        self.assertIn("github-pat", f[0].snippet)
        self.assertIn("abcdef1", f[0].snippet)
        f = checks(self.run_local(repo, ctx(tools={"gitleaks": fake}, visibility="private")), "A1")
        self.assertEqual([x.severity for x in f], ["HIGH"])

    def test_a1_tool_crash_is_unknown(self):
        fake = self.tmp / "crash"
        fake.write_text("#!/bin/sh\nexit 7\n")
        fake.chmod(0o755)
        repo = self.make_repo("proj-b", CLEAN_FILES)
        self.assertEqual([x.severity for x in checks(self.run_local(repo, ctx(tools={"gitleaks": fake})), "A1")],
                         ["UNKNOWN"])

    @unittest.skipUnless(shutil.which("gitleaks") or os.environ.get("KIT_TOOLS"), "real gitleaks not available")
    def test_a1_real_gitleaks(self):
        exe = shutil.which("gitleaks") or str(Path(os.environ["KIT_TOOLS"]) / "gitleaks")
        token = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        repo = self.make_repo("proj-c", {"cfg.env": f"GITHUB_TOKEN={token}\n"})
        f = checks(self.run_local(repo, ctx(tools={"gitleaks": Path(exe)})), "A1")
        self.assertTrue(f and f[0].severity == "CRITICAL", f)
        self.assertNotIn(token, json.dumps([x.__dict__ for x in f]))

    def test_a12_parses_osv_and_status(self):
        fake = self.tmp / "fake-osv"
        report = {"results": [{"source": {"path": "package-lock.json"}, "packages": [
            {"package": {"name": "left-pad", "version": "1.0.0"}, "groups": [{"ids": ["GHSA-x"], "max_severity": "9.8"}]},
            {"package": {"name": "ok-pkg", "version": "1.0.0"}, "groups": [{"ids": ["GHSA-y"], "max_severity": "3.1"}]}]}]}
        fake.write_text("#!/bin/sh\ncat <<'J'\n" + json.dumps(report) + "\nJ\nexit 1\n")
        fake.chmod(0o755)
        repo = self.make_repo("proj-b", dict(CLEAN_FILES, **{"package-lock.json": "{}\n"}))
        f = checks(self.run_local(repo, ctx(tools={"osv-scanner": fake}, project_status="active")), "A12")
        self.assertEqual([x.severity for x in f], ["HIGH"])
        self.assertIn("left-pad", f[0].snippet)
        f = checks(self.run_local(repo, ctx(tools={"osv-scanner": fake}, project_status="done")), "A12")
        self.assertEqual([x.severity for x in f], ["MEDIUM"])
        f = checks(self.run_local(repo, ctx(tools={})), "A12")
        self.assertEqual([x.severity for x in f], ["UNKNOWN"])

    def test_redact(self):
        self.assertEqual(redact(f"id={UID}!", PRIV), "id=<t-uid>!")
        self.assertEqual(redact("x " + UID.upper(), PRIV), "x <t-uid>")
        self.assertEqual(redact("path /home/testuser/x", PRIV), "path /home/<user>/x")
        self.assertIn("***", redact("token ghp_" + "a" * 36, None))

    def test_finding_shape(self):
        f = Finding("r", "A4", "HIGH", ".claude/x", None, "s", "fix")
        self.assertEqual(f.__dict__, {"repo": "r", "check": "A4", "severity": "HIGH", "path": ".claude/x",
                                      "line": None, "snippet": "s", "fix": "fix"})
