"""Audit scan set: local clones under [audit].root ∪ `gh repo list <owner>`, minus the
[audit].exclude globs from the LOCAL config (fleet exclusions never live in the repo)."""
import fnmatch
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from cli import gitutil, paths


@dataclass
class Target:
    name: str
    path: Path | None
    remote: str | None              # "owner/name" on GitHub, when known
    gh_visibility: str | None = None   # from gh repo list (public|private)
    archived: bool = False


@dataclass
class AuditCtx:
    privacy: object | None
    kittoml: object | None
    visibility: str
    tools: dict = field(default_factory=dict)
    offline: bool = False
    gh_repo: dict | None = None
    project_status: str | None = None
    default_workflow_write: bool | None = None


def _remote(path: Path) -> str | None:
    url = gitutil.config_get(path, "remote.origin.url")
    gh = gitutil.parse_github_remote(url) if url else None
    return f"{gh[0]}/{gh[1]}" if gh else None


def local_targets(root: Path) -> list[Target]:
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        if d.is_dir() and not d.name.startswith(".") and (d / ".git").exists():
            out.append(Target(d.name, d, _remote(d)))
    return out


def excluded(name: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def scan_targets(cfg: dict, names: list[str] | None = None, gh=None, owner: str | None = None) -> list[Target]:
    audit = cfg.get("audit", {}) if isinstance(cfg.get("audit"), dict) else {}
    root = paths.expand(audit.get("root", "~"))
    exclude = [p for p in audit.get("exclude", []) if isinstance(p, str)]
    targets = local_targets(root)
    by_remote = {t.remote.lower(): t for t in targets if t.remote}
    if gh is not None and owner:
        for r in gh.repo_list(owner) or []:
            full = f"{owner}/{r.get('name')}"
            vis = str(r.get("visibility", "")).lower() or None
            t = by_remote.get(full.lower())
            if t:
                t.gh_visibility = vis
                t.archived = bool(r.get("isArchived"))
            elif not r.get("isArchived"):
                targets.append(Target(r.get("name"), None, full, vis, False))
    targets = [t for t in targets if not excluded(t.name, exclude)]
    if names:
        targets = [t for t in targets if t.name in names]
    return sorted(targets, key=lambda t: t.name)
