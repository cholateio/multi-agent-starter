"""Phase 5 acceptance: kit init renders the v5 templates; no placeholder leaks, links resolve,
README recipe + workflow pass the audit checks (A10/A11/A15), workflow passes actionlint.
Every literal is invented (Lanternfish is a fictional project)."""
import datetime
import re
import shutil
import subprocess
import unittest
from pathlib import Path

from tests.unit._helpers import IsolatedTestCase, KIT_ROOT
from cli import init_cmd
from cli.audit import checks_local as cl
from cli.audit.scan import Target, AuditCtx

TPL = KIT_ROOT / "plugin" / "templates"
LOCAL_LITERALS = re.compile(r"/home/[a-z_][a-z0-9_-]*/|/mnt/c/Users/|NT\$|US\$|cholate", re.I)


class Args:
    def __init__(self, **kw):
        self.private = False
        self.license = "MIT"
        self.lang = "en"
        self.owner = "Acme Org"
        self.__dict__.update(kw)


class Rendered(IsolatedTestCase):
    def init(self, name="demo", **kw):
        d = self.tmp / name
        args = Args(dir=str(d), **kw)
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(init_cmd.run(args), 0)
        return d

    def a10_a11_a15(self, repo, vis="public"):
        tracked = subprocess.run(["git", "-C", str(repo), "ls-files"], capture_output=True, text=True).stdout.split()
        ctx = AuditCtx(privacy=None, kittoml=None,
                       visibility=vis, tools={}, offline=True, gh_repo=None, project_status=None)
        t = Target(repo.name, repo, None)
        return cl.a10_a11(t, ctx, tracked), cl.a15(t, ctx, tracked)


class TestTemplateFiles(unittest.TestCase):
    def test_project_toml_template_is_not_a_forbidden_path(self):
        self.assertFalse((TPL / "PROJECT.toml").exists(), "R2 forbids tracking PROJECT.toml")
        self.assertTrue((TPL / "PROJECT.toml.example").is_file())

    def test_agents_sections(self):
        t = (TPL / "AGENTS.md").read_text()
        heads = re.findall(r"^## (.+)$", t, re.M)
        self.assertEqual(heads, ["Project goal", "Stack", "File layout", "Constraints", "Conventions", "Where to look"])
        self.assertTrue(t.startswith("<!-- Tool-neutral project memory."))
        self.assertIn("kit.toml [protected]", t)
        self.assertIn("permissions: contents: read", t)
        self.assertIn("# vX.Y.Z", t)

    def test_development_sections(self):
        t = (TPL / "DEVELOPMENT.md").read_text()
        heads = re.findall(r"^## (.+)$", t, re.M)
        self.assertEqual(heads, ["Restart in 30 seconds", "Commands", "Environment variables", "Deploy",
                                 "Easy to forget", "Docs map"])
        self.assertIn("no values", t.lower())
        self.assertNotRegex(t, r"(?i)hand ?off|叫 AI|kit update|init\.sh")

    def test_private_readme_short(self):
        lines = (TPL / "README.private.md").read_text().splitlines()
        self.assertLessEqual(len(lines), 15)
        self.assertIn("docs/DEVELOPMENT.md", "\n".join(lines))

    def test_public_readme_recipe_headings(self):
        t = (TPL / "README.public.md").read_text()
        self.assertEqual(re.findall(r"^## (.+)$", t, re.M),
                         ["How it works", "Install", "Privacy & security", "License"])
        self.assertEqual(len(re.findall(r"^# ", t, re.M)), 1)
        self.assertIn("no-UI fallback", t)
        self.assertIn('width="72%"', t)
        self.assertIn('width="24%"', t)
        self.assertEqual(len(re.findall(r"^- \*\*[^*]+\*\*: ", t, re.M)), 4)

    def test_example_is_wholly_fictional_and_audit_clean(self):
        ex = TPL / "examples" / "README.lanternfish.md"
        t = ex.read_text()
        self.assertIn("Lanternfish", t)
        self.assertNotRegex(t, LOCAL_LITERALS)
        self.assertNotRegex(t, r"\[[^\]]*\]\((?!https?://|\.{0,2}/?[\w./-]+\))")  # no half-links
        self.assertNotRegex(t, r"(?m)^\[[A-Z][^\]]*\]$")
        self.assertNotIn("<!--", t)   # filled in, no template comments
        d = Path(__import__("tempfile").mkdtemp())
        try:
            (d / "README.md").write_text(t)
            subprocess.run(["git", "-C", str(d), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(d), "add", "-A"], check=True)
            ctx = AuditCtx(privacy=None, kittoml=None, visibility="public", tools={}, offline=True,
                           gh_repo=None, project_status=None)
            f = cl.a15(Target("x", d, None), ctx, ["README.md"])
            self.assertEqual(f, [], f)
            self.assertEqual(re.findall(r"^## (.+)$", t, re.M),
                             ["How it works", "Install", "Privacy & security", "License"])
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_license_texts(self):
        mit = (TPL / "LICENSE.MIT").read_text()
        self.assertTrue(mit.startswith("MIT License"))
        self.assertIn("{{YEAR}} {{OWNER}}", mit)
        cc = (TPL / "LICENSE.CC-BY-4.0").read_text()
        self.assertIn("Attribution 4.0 International", cc)
        self.assertIn("{{YEAR}} {{OWNER}}", cc)
        for marker in ("Section 1 -- Definitions.", "Section 2 -- Scope.", "Section 3 -- License Conditions.",
                       "Section 4 -- Sui Generis Database Rights.", "Section 5 -- Disclaimer of Warranties and Limitation of Liability.",
                       "Section 6 -- Term and Termination.", "Section 7 -- Other Terms and Conditions.",
                       "Section 8 -- Interpretation."):
            self.assertIn(marker, cc)
        self.assertGreater(len(cc), 15000)


class TestWorkflow(unittest.TestCase):
    wf = TPL / "github" / "workflows" / "kit-guard.yml"

    def test_shape(self):
        t = self.wf.read_text()
        lines = t.splitlines()
        self.assertTrue(any(re.match(r"^permissions:\s*$", l) for l in lines))
        self.assertRegex(t, r"(?m)^permissions:\n  contents: read$")
        self.assertNotIn("write", re.sub(r"#.*", "", t))
        uses = re.findall(r"^\s*-?\s*uses:\s*(\S+)(.*)$", t, re.M)
        self.assertTrue(uses)
        for ref, rest in uses:
            self.assertRegex(ref, r"@[0-9a-f]{40}$")
            self.assertRegex(rest, r"#\s*v\d+\.\d+\.\d+")
        self.assertIn("sha256sum -c", t)
        self.assertNotIn("gitleaks-action", t)
        self.assertNotRegex(t, r"(?i)cholate|/home/[a-z_][a-z0-9_-]*/")
        self.assertRegex(t, r"gitleaks\" git --redact")

    def test_gitleaks_pin_matches_doctor(self):
        from cli.doctor import TOOL_PINS
        p = TOOL_PINS["gitleaks"]
        t = self.wf.read_text()
        self.assertIn(p.url, t)
        self.assertIn(p.sha256, t)

    def test_actionlint(self):
        if not shutil.which("docker"):
            self.skipTest("docker not available")
        if subprocess.run(["docker", "image", "inspect", "rhysd/actionlint:1.7.12"], capture_output=True).returncode:
            self.skipTest("rhysd/actionlint:1.7.12 not pulled")
        r = subprocess.run(["docker", "run", "--rm", "-i", "rhysd/actionlint:1.7.12", "-color", "-"],
                           input=self.wf.read_bytes(), capture_output=True)
        self.assertEqual(r.returncode, 0, r.stdout.decode() + r.stderr.decode())


class TestRendered(Rendered):
    def test_public_mit(self):
        d = self.init()
        for f in d.rglob("*"):
            if f.is_file() and ".git" not in f.parts:
                self.assertNotRegex(f.read_text(), r"\{\{[A-Z_]+\}\}", f"placeholder leak in {f}")
        lic = (d / "LICENSE").read_text()
        self.assertTrue(lic.startswith("MIT License"))
        self.assertIn("[MIT](LICENSE)", (d / "README.md").read_text())
        self.assertIn(f"{datetime.date.today().year} Acme Org", lic)
        self.assertEqual(re.findall(r"^## ", (d / "AGENTS.md").read_text(), re.M).__len__(), 6)
        self.assertIn("## Environment variables", (d / "docs" / "DEVELOPMENT.md").read_text())
        self.assertTrue((d / ".github/workflows/kit-guard.yml").is_file())
        self.assertTrue((d / "PROJECT.toml").is_file())
        self.assertFalse((d / "PROJECT.toml.example").exists())
        tracked = subprocess.run(["git", "-C", str(d), "ls-files"], capture_output=True, text=True).stdout.split()
        self.assertNotIn("PROJECT.toml", tracked)
        wf, rd = self.a10_a11_a15(d)
        self.assertEqual(wf, [], wf)
        self.assertEqual(rd, [], rd)

    def ci_step(self, d):
        wf = (d / ".github/workflows/kit-guard.yml").read_text()
        m = re.search(r"- name: kit privacy\n(?:\s+if:.*\n)?\s+run: \|\n((?:\s{10}.*\n?)+)", wf)
        self.assertTrue(m)
        script = "\n".join(l[10:] for l in m.group(1).splitlines())
        return lambda: subprocess.run(["bash", "-c", script], cwd=d, capture_output=True, text=True)

    def stage(self, d, name, text):
        f = d / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
        subprocess.run(["git", "-C", str(d), "add", "-f", name], check=True)

    def test_ci_matches_local_guard_forbidden_paths(self):
        d = self.init()
        run = self.ci_step(d)
        self.stage(d, ".env", "K=v\n")
        self.assertNotEqual(run().returncode, 0, ".env must fail CI like the local guard")
        subprocess.run(["git", "-C", str(d), "rm", "-qf", ".env"], check=True)
        self.stage(d, ".env.example", "K=\n")
        self.assertEqual(run().returncode, 0, ".env.example is allowed")
        for name in ("sub/PROJECT.toml", "pkg/CLAUDE.local.md", "a/b/x.local.toml", "docs/superpowers/plans/p.md"):
            self.stage(d, name, "x\n")
            self.assertNotEqual(run().returncode, 0, name)
            subprocess.run(["git", "-C", str(d), "rm", "-qf", name], check=True)

    def test_ci_home_path_is_a_warning_windows_path_fails_and_allow_marker_works(self):
        d = self.init()
        run = self.ci_step(d)
        self.stage(d, "Dockerfile", "WORKDIR /ho" + "me/node/app\n")
        r = run()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("::warning::", r.stdout)
        self.stage(d, "doc.txt", "see /mnt/" + "c/Users/someone/x\n")
        self.assertNotEqual(run().returncode, 0)
        self.stage(d, "doc.txt", "see /mnt/" + "c/Users/someone/x  # kit-privacy: allow\n")
        self.assertEqual(run().returncode, 0)

    def test_ci_privacy_step_passes_on_fresh_project_and_catches_leaks(self):
        d = self.init()
        run = self.ci_step(d)
        self.assertEqual(run().returncode, 0, run().stdout)   # no self-match of its own patterns
        (d / "notes.txt").write_text("see /mnt/" + "c/Users/someone/x\n")
        subprocess.run(["git", "-C", str(d), "add", "-f", "notes.txt"], check=True)
        self.assertNotEqual(run().returncode, 0)
        subprocess.run(["git", "-C", str(d), "rm", "-qf", "notes.txt"], check=True)
        (d / "PROJECT.toml").write_text("x\n")
        subprocess.run(["git", "-C", str(d), "add", "-f", "PROJECT.toml"], check=True)
        self.assertNotEqual(run().returncode, 0)

    def test_links_resolve(self):
        d = self.init()
        for md in (d / "README.md", d / "AGENTS.md", d / "docs" / "DEVELOPMENT.md"):
            text = re.sub(r"<!--.*?-->", "", md.read_text(), flags=re.S)
            for m in re.finditer(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)", text):
                target = m.group(1)
                if target.startswith(("http://", "https://", "#", "mailto:")):
                    continue
                base = md.parent
                self.assertTrue((base / target.split("#")[0]).exists(), f"{md.name}: dead link {target}")

    def test_cc_by(self):
        d = self.init("cc", license="CC-BY-4.0")
        t = (d / "LICENSE").read_text()
        self.assertIn("Attribution 4.0 International", t)
        self.assertIn(f"{datetime.date.today().year} Acme Org", t)
        self.assertNotIn("{{", t)
        self.assertIn("[CC BY 4.0](LICENSE)", (d / "README.md").read_text())
        self.assertNotIn("[MIT]", (d / "README.md").read_text())

    def test_license_none_public_readme_has_no_dead_link(self):
        d = self.init("nl", license="none")
        r = (d / "README.md").read_text()
        self.assertNotIn("](LICENSE)", r)
        self.assertNotIn("{{", r)
        self.assertIn("All rights reserved", r)

    def test_private(self):
        d = self.init("pv", private=True, license="none")
        self.assertLessEqual(len((d / "README.md").read_text().splitlines()), 15)
        self.assertFalse((d / ".github").exists())
        self.assertFalse((d / "LICENSE").exists())
        for f in ("AGENTS.md", "README.md", "docs/DEVELOPMENT.md"):
            self.assertNotRegex((d / f).read_text(), LOCAL_LITERALS, f)


if __name__ == "__main__":
    unittest.main()
