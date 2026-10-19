"""GitHub-side audit checks (design §8): A6 A7 A8 A9 A14 A18. READ-ONLY: only
`gh api <path>` GETs (no -X / -f / -F, which would switch gh to a write method).
gh missing / logged out / offline / no GitHub remote → UNKNOWN (never HIGH, never
affects the exit code)."""
import json
import shutil
import subprocess
from pathlib import Path

from cli.audit.report import Finding

GH_CHECKS = ("A6", "A7", "A8", "A9", "A14", "A18")


class GhClient:
    def __init__(self, offline_dir: Path | None = None):
        self.offline_dir = Path(offline_dir) if offline_dir else None
        self.data: dict = {}
        if self.offline_dir:
            for f in sorted(self.offline_dir.glob("*.json")):
                self.data.update(json.loads(f.read_text()))
        self._ok = None
        self._cache: dict = {}

    def available(self) -> bool:
        if self.offline_dir:
            return True
        if self._ok is None:
            self._ok = bool(shutil.which("gh")) and subprocess.run(
                ["gh", "auth", "status"], capture_output=True).returncode == 0
        return self._ok

    def call(self, path: str):
        """(status, body): 200/204/403/404, or (None, None) when unknown."""
        if path in self._cache:
            return self._cache[path]
        if self.offline_dir:
            if path not in self.data:
                res = (None, None)
            else:
                body = self.data[path]
                res = ((body["__status"], None) if isinstance(body, dict) and "__status" in body else (200, body))
        elif not self.available():
            res = (None, None)
        else:
            r = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path],
                               capture_output=True, text=True)
            if r.returncode == 0:
                try:
                    res = (200, json.loads(r.stdout)) if r.stdout.strip() else (204, None)
                except ValueError:
                    res = (None, None)
            elif "HTTP 404" in r.stderr:
                res = (404, None)
            elif "HTTP 403" in r.stderr:
                res = (403, None)
            else:
                res = (None, None)
        self._cache[path] = res
        return res

    def get(self, path: str):
        status, body = self.call(path)
        return body if status == 200 else None

    def login(self) -> str | None:
        if self.offline_dir:
            return (self.data.get("user") or {}).get("login")
        u = self.get("user")
        return u.get("login") if isinstance(u, dict) else None

    def repo_list(self, owner: str):
        if self.offline_dir:
            return self.data.get(f"gh repo list {owner}", [])
        if not self.available():
            return None
        r = subprocess.run(["gh", "repo", "list", owner, "--json", "name,visibility,isArchived", "-L", "200"],
                           capture_output=True, text=True)
        try:
            return json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError:
            return None


def _unknown(t, check, why):
    return Finding(t.name, check, "UNKNOWN", None, None, why, "")


def run_github_checks(t, ctx, gh: GhClient) -> list:
    out = []
    # A6 (local half): a v4 kit project with no kit.toml
    if t.path is not None and ctx.kittoml is None and (Path(t.path) / ".claude" / "kit-version").is_file():
        out.append(Finding(t.name, "A6", "HIGH", "kit.toml", None, "kit project without kit.toml (v4 layout)",
                           "kit migrate"))
    if not t.remote:
        return out + [_unknown(t, c, "no GitHub remote") for c in GH_CHECKS if not (c == "A6" and out)]
    repo = gh.get(f"repos/{t.remote}")
    if repo is None:
        why = "gh unavailable (missing / logged out / offline)" if not gh.available() else "repo not readable via gh"
        return out + [_unknown(t, c, why) for c in GH_CHECKS if not (c == "A6" and out)]
    vis = str(repo.get("visibility", "")).lower()
    public = vis == "public"
    # A6: kit.toml visibility vs GitHub
    if ctx.kittoml is not None and vis and ctx.kittoml.visibility != vis:
        out.append(Finding(t.name, "A6", "HIGH", "kit.toml", None,
                           f"kit.toml visibility={ctx.kittoml.visibility}, GitHub says {vis}",
                           f'set visibility = "{vis}" in kit.toml (guard tier R5 depends on it)'))
    # A7: secret scanning / push protection (public)
    if public:
        saa = repo.get("security_and_analysis")
        if not isinstance(saa, dict):
            out.append(_unknown(t, "A7", "security_and_analysis not visible (needs admin)"))
        else:
            off = [k for k in ("secret_scanning", "secret_scanning_push_protection")
                   if (saa.get(k) or {}).get("status") != "enabled"]
            if off:
                out.append(Finding(t.name, "A7", "HIGH", None, None, "disabled: " + ", ".join(off),
                                   "Settings → Code security → enable secret scanning + push protection"))
    # A8: Dependabot alerts
    st, _ = gh.call(f"repos/{t.remote}/vulnerability-alerts")
    if st == 404:
        out.append(Finding(t.name, "A8", "MEDIUM", None, None, "Dependabot alerts disabled",
                           "Settings → Code security → Dependabot alerts"))
    elif st not in (200, 204):
        out.append(_unknown(t, "A8", "vulnerability-alerts not readable"))
    # A9: default workflow token permissions
    wp = gh.get(f"repos/{t.remote}/actions/permissions/workflow")
    if wp is None:
        out.append(_unknown(t, "A9", "actions/permissions/workflow not readable"))
    else:
        ctx.default_workflow_write = wp.get("default_workflow_permissions") == "write"
        if ctx.default_workflow_write:
            out.append(Finding(t.name, "A9", "HIGH", None, None, "default GITHUB_TOKEN permission = write",
                               "Settings → Actions → Workflow permissions → Read repository contents"))
    if public:
        # A14: description / topics
        miss = [k for k in ("description", "topics") if not repo.get(k)]
        if miss:
            out.append(Finding(t.name, "A14", "LOW", None, None, "missing " + " + ".join(miss),
                               "gh repo edit --description … --add-topic …"))
        # A18: rulesets / branch protection on the default branch
        rs_st, rs = gh.call(f"repos/{t.remote}/rulesets")
        br = repo.get("default_branch") or "main"
        bp_st, _ = gh.call(f"repos/{t.remote}/branches/{br}/protection")
        if rs_st == 200 and not rs and bp_st == 404:
            out.append(Finding(t.name, "A18", "LOW", None, None, f"no ruleset / branch protection on {br}",
                               "add a ruleset (single-owner fleet: advisory)"))
        elif rs_st != 200 or bp_st not in (200, 404):
            if not (rs_st == 200 and rs):
                out.append(_unknown(t, "A18", "rulesets / protection not readable"))
    return out
