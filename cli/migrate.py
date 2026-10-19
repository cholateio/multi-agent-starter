"""kit migrate <dir> [--apply] [--commit] [--allow-dirty] — v4 project → v5 (design §9, D17).

Dry-run by default. Never loses content: a local backup is taken before the
first change, CLAUDE.md content moves to AGENTS.md (whole file when the kit
boilerplate cannot be recognised), user files under .claude/ are kept, and
every step is idempotent (a re-run converges, then reports nothing to do).
Handles repos whose .claude/ is already untracked but still holds v4 files.

Order matters for the half-migrated window: kit.toml is written first and
.claude/kit-version is deleted LAST, so until the very end the plugin hooks
yield to the v4 hooks (plugin/hooks/lib.sh) and nothing fires twice.
"""
import datetime
import difflib
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from cli import gitutil, init_cmd, kittoml, paths

UNTRACK = [".claude", "PROJECT.toml", "docs/LESSONS.md", "docs/plans", "docs/superpowers/plans", "docs/decisions"]
BACKUP = UNTRACK + ["CLAUDE.md", ".gitignore"]
WRITES = ["kit.toml", "AGENTS.md", "CLAUDE.md", ".gitignore", "LICENSE", "docs/DEVELOPMENT.md"]
MANAGED = UNTRACK + WRITES
COMMIT_MSG = "chore(kit): migrate to kit v5 — untrack .claude, add AGENTS.md + kit.toml"

V4_KIT_FILES = {
    "rules": ["kit-workflow.md", "kit-delegation.md", "kit-judgment.md", "kit-evolution.md", "project-manifest.md"],
    "hooks": ["session-start.sh", "classify-task.sh", "protect-paths.sh", "tool-breaker.sh", "verify-final-review.sh"],
    "agents": ["research-scout.md", "solo-reviewer.md"],
    "docs": ["judgment-matrix.md", "verification-signals.md"],
}
V4_KIT_SKILLS = ["kit-review", "kit-skip-review", "kit-dispatch", "research-before-planning"]
V4_BASELINE = ["Bash(timeout *)", "Bash(git status)", "Bash(git status *)", "Bash(git diff)", "Bash(git diff *)",
               "Bash(git log)", "Bash(git log *)", "Bash(git show *)", "Bash(ls)", "Bash(ls *)"]
MIRRORED = ("Path-type constraints above are mirrored in `kit.toml [protected]` "
            "(the PreToolUse hook enforces them).")
TEMPLATE_HEADINGS = ("Project goal", "Stack", "File layout", "Project-specific constraints")
ROUTE_HEADING_RE = re.compile(r"^## (檔案路由|Multi-agent kit|Kit routing)")
QUOTE_RE = re.compile(r"^> CLAUDE\.md[（(]kit")
README_PROMPT = ("Using AGENTS.md and docs/, rewrite README.md with the kit README recipe "
                 "(public: RepoBox recipe in English; private: short version), move developer content to "
                 "docs/DEVELOPMENT.md, no local paths / costs / personal data; show me the diff first.")


# ------------------------------------------------------------------ pure helpers
def _stub_text() -> str:
    return (paths.templates_dir() / "CLAUDE.md").read_text(encoding="utf-8")


def is_stub(text: str) -> bool:
    first = next((l.strip() for l in text.splitlines() if l.strip()), "")
    return first == "@AGENTS.md"


def split_claude_md(text: str) -> tuple[str, str, bool]:
    """(agents_md, claude_stub, needs_review). Strips the v4 kit boilerplate: (a) the
    leading `> CLAUDE.md（kit …` blockquote, (b) the `**同步執法**` paragraph (replaced
    by one sentence), (c) the routing section (`## 檔案路由` / `## Multi-agent kit` /
    `## Kit routing …`) up to the next `## `. No marker found → whole text, needs_review."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    found = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if QUOTE_RE.match(line):
            found = True
            while i < len(lines) and lines[i].startswith(">"):
                i += 1
            if i < len(lines) and not lines[i].strip():
                i += 1
            continue
        if line.startswith("**同步執法**"):
            found = True
            while i < len(lines) and lines[i].strip():
                i += 1
            out.append(MIRRORED + "\n")
            continue
        if ROUTE_HEADING_RE.match(line):
            found = True
            i += 1
            while i < len(lines) and not lines[i].startswith("## "):
                i += 1
            continue
        out.append(line)
        i += 1
    headings = [l[3:].strip() for l in lines if l.startswith("## ") and not ROUTE_HEADING_RE.match(l)]
    extra = [h for h in headings if not h.startswith(TEMPLATE_HEADINGS)]
    stub = _stub_text()
    if extra and found:
        stub += ("<!-- kit migrate: non-template sections now live in AGENTS.md: "
                 + ", ".join(f'"{h}"' for h in extra)
                 + ". Move Claude-only ones here. -->\n")
    if not found:
        return text, stub, True
    agents = "".join(out).replace(".claude/protected-paths", "kit.toml [protected]")
    agents = re.sub(r"\n{3,}", "\n\n", agents).rstrip("\n") + "\n"
    return agents, stub, False


ABS_RE = re.compile(r"^(/|~|[A-Za-z]:[\\/]|\\\\)")


def protected_from_v4(text: str) -> tuple[list[str], list[str]]:
    """(items, rejected). `#` lines kept as comment items; absolute / home paths are
    rejected — kit.toml is tracked and repo-relative (privacy + design §5.2)."""
    items, rejected = [], []
    for raw in text.splitlines():
        s = raw.strip()
        if not s:
            continue
        if s.startswith("#"):
            items.append(s)
        elif ABS_RE.match(s):
            rejected.append(s)
        else:
            items.append(s)
    return items, rejected


def render_kit_toml(visibility: str, license: str, protected: list[str]) -> str:
    return kittoml.render_kit_toml(visibility, license, "en", protected)


def strip_kit_settings(settings: dict) -> dict | None:
    """Remove the kit's hooks (commands under .claude/hooks/), the v4 permission
    baseline and the template _comment; None when nothing user-owned remains."""
    s = json.loads(json.dumps(settings))
    if isinstance(s.get("_comment"), str) and s["_comment"].startswith("kit settings template"):
        del s["_comment"]
    hooks = s.get("hooks")
    if isinstance(hooks, dict):
        for ev in list(hooks):
            groups = []
            for g in hooks[ev] if isinstance(hooks[ev], list) else []:
                hs = [h for h in g.get("hooks", []) if ".claude/hooks/" not in str(h.get("command", ""))]
                if hs:
                    groups.append({**g, "hooks": hs})
            if groups:
                hooks[ev] = groups
            else:
                del hooks[ev]
        if not hooks:
            del s["hooks"]
    perms = s.get("permissions")
    if isinstance(perms, dict):
        if isinstance(perms.get("allow"), list):
            perms["allow"] = [a for a in perms["allow"] if a not in V4_BASELINE]
            if not perms["allow"]:
                del perms["allow"]
        if not perms:
            del s["permissions"]
    return s or None


def merge_settings(local: dict, residual: dict) -> dict:
    """Merge residual project settings into settings.local.json; local wins on
    scalars, permission lists are unioned (local order first)."""
    out = json.loads(json.dumps(local))
    for k, v in residual.items():
        if k == "permissions" and isinstance(v, dict):
            p = out.setdefault("permissions", {})
            for pk, pv in v.items():
                if isinstance(pv, list):
                    cur = p.setdefault(pk, [])
                    cur.extend(x for x in pv if x not in cur)
                else:
                    p.setdefault(pk, pv)
        elif k == "hooks" and isinstance(v, dict):
            h = out.setdefault("hooks", {})
            for ev, groups in v.items():
                h.setdefault(ev, [])
                h[ev].extend(g for g in groups if g not in h[ev])
        else:
            out.setdefault(k, v)
    return out


def remove_v4_gitignore_block(text: str) -> str:
    """Drop v4's '`.claude/` itself IS tracked on purpose' comment block and its
    two .claude/ entries (superseded by the kit block's `.claude/`)."""
    lines = text.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("# Claude Code runtime state"):
            i += 1
            while i < len(lines) and (lines[i].startswith("#") or lines[i].strip().startswith(".claude/")):
                i += 1
            if out and not out[-1].strip() and i < len(lines) and not lines[i].strip():
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return "".join(out)


def _license_kind(text: str) -> str | None:
    if "Permission is hereby granted, free of charge" in text or text.lstrip().startswith("MIT License"):
        return "MIT"
    if "Attribution 4.0 International" in text:
        return "CC-BY-4.0"
    return None


# ------------------------------------------------------------------ migration
@dataclass
class Result:
    status: str          # done | skip | would | needs-review
    step: str
    detail: str = ""
    diff: str = ""
    change: bool = False  # this step writes something


class StopForTest(Exception):
    pass


@dataclass
class Migration:
    root: Path
    act: bool = False
    visibility_override: str | None = None
    results: list[Result] = field(default_factory=list)
    _visibility: str | None = None

    def r(self, status, step, detail="", diff="", change=None):
        if change is None:
            change = status == "would"
        if status == "would" and self.act:
            status = "done"
        self.results.append(Result(status, step, detail, diff, change))

    def p(self, rel) -> Path:
        return self.root / rel

    # -- visibility (gh, read-only; offline → public, fail-closed)
    def visibility(self) -> str:
        if self.visibility_override:
            return self.visibility_override
        if self._visibility:
            return self._visibility
        vis = None
        url = gitutil.config_get(self.root, "remote.origin.url")
        gh = gitutil.parse_github_remote(url) if url else None
        if gh and shutil.which("gh"):
            r = subprocess.run(["gh", "api", f"repos/{gh[0]}/{gh[1]}", "--jq", ".visibility"],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip() in ("public", "private", "internal"):
                vis = "public" if r.stdout.strip() == "public" else "private"
        if vis is None:
            print("WARN: offline, assuming public" + ("" if gh else " (no GitHub origin)"))
            vis = "public"
        self._visibility = vis
        return vis

    # -- steps
    def step_kit_toml(self):
        kt = self.p("kit.toml")
        if kt.exists():
            errs = kittoml.validate_kit_toml(kt)
            if errs:
                self.r("needs-review", "kit.toml", "exists but invalid (left as is): " + "; ".join(errs[:2]))
            else:
                self.r("skip", "kit.toml", "exists")
            return
        vis = self.visibility()
        lic_path = self.p("LICENSE")
        lic_text = lic_path.read_text(errors="replace") if lic_path.is_file() else ""
        kind = _license_kind(lic_text)
        if kind is None and lic_text.strip():
            self.r("needs-review", "kit.toml license", "LICENSE is neither MIT nor CC-BY-4.0; kit.toml says none")
        license = kind or ("MIT" if vis == "public" and not lic_text.strip() else "none")
        pp = self.p(".claude/protected-paths")
        items, rejected = protected_from_v4(pp.read_text(errors="replace")) if pp.is_file() else ([], [])
        if rejected:
            self.r("needs-review", "kit.toml protected",
                   f"{len(rejected)} absolute path(s) in .claude/protected-paths NOT carried into the tracked "
                   "kit.toml (privacy; kit.toml is repo-relative) — see the backup copy")
        text = render_kit_toml(vis, license, items)
        n = sum(1 for i in items if not i.startswith("#"))
        if self.act:
            kt.write_text(text, encoding="utf-8")
        self.r("would", "kit.toml", f"visibility={vis}, license={license}, protected={n}",
               diff="".join(difflib.unified_diff([], text.splitlines(True), "/dev/null", "kit.toml")))

    def step_agents(self):
        cm, am = self.p("CLAUDE.md"), self.p("AGENTS.md")
        ctext = cm.read_text(encoding="utf-8") if cm.is_file() else None
        if am.exists():
            if ctext is not None and is_stub(ctext):
                self.r("skip", "AGENTS.md", "exists; CLAUDE.md is the stub")
            elif ctext is None:
                if self.act:
                    cm.write_text(_stub_text(), encoding="utf-8")
                self.r("would", "CLAUDE.md", "stub (@AGENTS.md)")
            else:
                self.r("needs-review", "AGENTS.md", "AGENTS.md already exists and CLAUDE.md is not the stub — "
                       "merge CLAUDE.md into AGENTS.md by hand (both left untouched)")
            return
        if ctext is None:
            self.r("needs-review", "AGENTS.md", "no CLAUDE.md to convert — write AGENTS.md (template: kit init)")
            return
        if is_stub(ctext):
            self.r("needs-review", "AGENTS.md", "CLAUDE.md is already the stub but AGENTS.md is missing")
            return
        agents, stub, review = split_claude_md(ctext)
        diff = "".join(difflib.unified_diff(ctext.splitlines(True), stub.splitlines(True), "CLAUDE.md", "CLAUDE.md"))
        if self.act:
            am.write_text(agents, encoding="utf-8")
            cm.write_text(stub, encoding="utf-8")
        if review:
            self.r("needs-review", "AGENTS.md", "no kit boilerplate markers found — whole CLAUDE.md moved to "
                   "AGENTS.md verbatim; review it", diff, change=True)
        else:
            self.r("would", "AGENTS.md", f"from CLAUDE.md ({len(agents.splitlines())} lines); CLAUDE.md → stub", diff)
        if self.act and os.environ.get("KIT_TEST_MIGRATE_STOP_AFTER") == "agents":
            raise StopForTest("agents")

    def step_gitignore(self):
        gi = self.p(".gitignore")
        old = gi.read_text(encoding="utf-8") if gi.is_file() else ""
        new = init_cmd.with_gitignore_block(remove_v4_gitignore_block(old))
        if new == old:
            self.r("skip", ".gitignore", "kit block present")
            return
        if self.act:
            gi.write_text(new, encoding="utf-8")
        self.r("would", ".gitignore", "kit v5 block (managed markers); v4 tracked-on-purpose block removed",
               "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), ".gitignore", ".gitignore")))

    def step_untrack(self):
        tracked = gitutil.tracked_files(self.root, *UNTRACK)
        if not tracked:
            self.r("skip", "untrack", "nothing local-only is tracked")
            return
        if self.act:
            gitutil.run_git(self.root, "rm", "-r", "--cached", "-q", "--ignore-unmatch", "--", *UNTRACK)
        tops = sorted({t.split("/")[0] if t.startswith(".claude/") else t for t in tracked})
        self.r("would", "untrack", f"git rm --cached {len(tracked)} file(s): {', '.join(tops[:6])} (kept on disk)")

    def step_clean(self):
        cl = self.p(".claude")
        if not cl.is_dir():
            self.r("skip", "clean .claude", "no .claude/")
            return
        removed, unknown, notes = [], [], []
        # settings.json: strip kit hooks + baseline, residual → settings.local.json
        sj = cl / "settings.json"
        if sj.is_file():
            try:
                data = json.loads(sj.read_text())
            except ValueError:
                data = None
                self.r("needs-review", "clean .claude", ".claude/settings.json is not valid JSON — left as is")
            if isinstance(data, dict) and strip_kit_settings(data) != data:
                resid = strip_kit_settings(data)
                if self.act:
                    if resid:
                        lj = cl / "settings.local.json"
                        local = json.loads(lj.read_text()) if lj.is_file() else {}
                        lj.write_text(json.dumps(merge_settings(local, resid), indent=2, ensure_ascii=False) + "\n")
                    sj.unlink()
                notes.append("settings.json → " + ("settings.local.json (user allows kept)" if resid else "removed (kit-only)"))
        for d, names in V4_KIT_FILES.items():
            dd = cl / d
            for n in names:
                if (dd / n).is_file():
                    removed.append(f"{d}/{n}")
                    if self.act:
                        (dd / n).unlink()
        sk = cl / "skills"
        for s in V4_KIT_SKILLS:
            if (sk / s).is_dir():
                removed.append(f"skills/{s}/")
                if self.act:
                    shutil.rmtree(sk / s)
        gone = set(removed)
        for d in list(V4_KIT_FILES) + ["skills"]:
            dd = cl / d
            if not dd.is_dir():
                continue
            for p in sorted(dd.rglob("*")):
                rel = p.relative_to(cl).as_posix()
                if p.is_file() and rel not in gone and not any(rel.startswith(g) for g in gone if g.endswith("/")):
                    unknown.append(".claude/" + rel)
            if self.act:                        # prune now-empty directories only
                for dirpath, _, _ in sorted(os.walk(dd), key=lambda t: -len(t[0])):
                    if not os.listdir(dirpath):
                        os.rmdir(dirpath)
        if (cl / "protected-paths").is_file():
            removed.append("protected-paths")
            if self.act:
                (cl / "protected-paths").unlink()
        if (cl / "kit-version").is_file():     # LAST: until now the plugin hooks yield to v4's
            removed.append("kit-version")
            if self.act:
                (cl / "kit-version").unlink()
        if removed or notes:
            self.r("would", "clean .claude", f"removed {len(removed)} kit file(s)" + (f"; {'; '.join(notes)}" if notes else ""))
            if unknown:
                self.r("needs-review", "clean .claude", "kept non-kit file(s): " + ", ".join(unknown[:8]))
        else:
            self.r("skip", "clean .claude", "no v4 kit files" + (f" (kept user files: {', '.join(unknown[:5])})" if unknown else ""))

    def step_extras(self):
        vis = (kittoml.parse_kit_toml(self.p("kit.toml")).visibility if self.p("kit.toml").is_file()
               else self.visibility())
        lic = self.p("LICENSE")
        if vis == "public" and (not lic.is_file() or lic.stat().st_size == 0):
            tpl = paths.templates_dir() / "LICENSE.MIT"
            if not tpl.is_file():
                self.r("skip", "LICENSE", "template missing")
            else:
                owner = gitutil.config_get(self.root, "user.name") or "the authors"
                text = (tpl.read_text().replace("{{YEAR}}", str(datetime.date.today().year))
                        .replace("{{OWNER}}", owner))
                if self.act:
                    lic.write_text(text, encoding="utf-8")
                self.r("would", "LICENSE", f"MIT ({'was empty' if lic.is_file() else 'was missing'}; public repo)")
        else:
            self.r("skip", "LICENSE", "present" if lic.is_file() and lic.stat().st_size else f"{vis} repo")
        dev = self.p("docs/DEVELOPMENT.md")
        if vis == "private" and not dev.exists():
            tpl = paths.templates_dir() / "DEVELOPMENT.md"
            if not tpl.is_file():
                self.r("skip", "docs/DEVELOPMENT.md", "template missing")
            else:
                if self.act:
                    dev.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(tpl, dev)
                self.r("would", "docs/DEVELOPMENT.md", "skeleton")

    STEPS = ("step_kit_toml", "step_agents", "step_gitignore", "step_untrack", "step_clean", "step_extras")

    def plan(self):
        for s in self.STEPS:
            getattr(self, s)()

    @property
    def pending(self) -> bool:
        return any(r.change for r in self.results)


def _dirty_outside_managed(root: Path) -> tuple[list[str], list[str]]:
    """(dirty paths outside the migration's own files, staged paths outside them)."""
    dirty, staged = [], []
    for e in gitutil.status_porcelain(root):
        path = e[3:]
        if any(path == m or path.startswith(m + "/") for m in MANAGED):
            continue
        dirty.append(path)
        if e[0] not in (" ", "?"):
            staged.append(path)
    return dirty, staged


def _backup(root: Path) -> Path:
    base = paths.state_dir() / "migrate-backup" / root.name
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest, n = base / stamp, 0
    while dest.exists():
        n += 1
        dest = base / f"{stamp}-{n}"
    dest.mkdir(parents=True)
    for rel in BACKUP:
        src = root / rel
        if src.is_dir():
            shutil.copytree(src, dest / rel, symlinks=True)
        elif src.is_file():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest / rel)
    return dest


def _print(results: list[Result], show_diff: bool):
    for r in results:
        print(f"{r.status} {r.step}" + (f" — {r.detail}" if r.detail else ""))
        if show_diff and r.diff:
            for line in r.diff.rstrip("\n").splitlines()[:80]:
                print("    " + line)


def run(args) -> int:
    from cli.main import KitError
    root = Path(args.dir).expanduser().resolve()
    if not gitutil.is_repo(root):
        raise KitError(f"{root} is not a git repository")
    top = gitutil.repo_root(root)
    if top and top.resolve() != root:
        raise KitError(f"run kit migrate on the repository root ({top}), not a subdirectory")
    v4 = (root / ".claude" / "kit-version").is_file() or (root / ".claude" / "rules" / "kit-workflow.md").is_file()
    v5 = (root / "kit.toml").is_file()
    if not v4 and not v5:
        raise KitError(f"{root} is not a kit v4 project (no .claude/kit-version) and has no kit.toml — "
                       "for a new project use: kit init")
    apply = args.apply or args.commit
    dirty, staged = _dirty_outside_managed(root)
    if dirty and not args.allow_dirty:
        raise KitError(f"working tree is dirty ({len(dirty)} path(s), e.g. {', '.join(dirty[:3])}) — "
                       "commit or stash first, or pass --allow-dirty")
    if args.commit and staged:
        raise KitError(f"staged changes outside the migration ({', '.join(staged[:3])}) would be swept into "
                       "the migration commit — commit or unstage them first")
    print(f"kit migrate {root} ({'v4 → v5' if v4 else 'v5: fill missing pieces'})"
          + ("" if apply else " — dry-run"))

    m = Migration(root, act=False, visibility_override=args.visibility)
    m.plan()
    pending = m.pending
    if not apply:
        _print(m.results, show_diff=True)
        print("\ndry-run: nothing written. Re-run with --apply (and --commit to commit)." if pending
              else "\nnothing to do — already migrated.")
        return 0

    if pending:
        bk = _backup(root)
        print(f"done backup — {bk}")
        m2 = Migration(root, act=True, visibility_override=args.visibility or m._visibility)
        try:
            m2.plan()
        except StopForTest as e:
            _print(m2.results, show_diff=False)
            print(f"(test) stopped after {e}")
            return 3
        _print(m2.results, show_diff=False)
    else:
        _print(m.results, show_diff=False)

    if args.commit:
        add = [w for w in WRITES if (root / w).exists()]
        if add:
            gitutil.run_git(root, "add", "--", *add)
        if subprocess.run(["git", "-C", str(root), "diff", "--cached", "--quiet"]).returncode != 0:
            r = subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", COMMIT_MSG], capture_output=True, text=True)
            if r.returncode != 0:
                print(f"needs-review commit — git commit failed: {(r.stderr or r.stdout).strip()[:300]}")
                return 1
            print(f"done commit — {COMMIT_MSG}")
            pending = True
        else:
            print("skip commit — nothing staged")

    if pending:
        print("\nnext (D18, README is content work — paste into a claude session in this repo):")
        print("  " + README_PROMPT)
        print("note: history still contains PROJECT.toml / LESSONS / plans if they were ever committed — "
              "history rewrite is a separate runbook (design §12 step 6).")
    else:
        print("\nnothing to do — already migrated.")
    return 0
