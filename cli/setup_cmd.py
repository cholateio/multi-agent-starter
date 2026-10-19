"""kit setup [--dry-run] [--uninstall] [--marketplace local|github]

One-time, idempotent machine setup (design §4.7). Every step prints
`[done|skip|warn] <step>`; --dry-run prints `WOULD RUN: <cmd>` / `WOULD WRITE: <path>`
and executes nothing (that output is the owner-action checklist, plan appendix A).
--uninstall reverses the plugin install, hooksPath, shims and symlinks; it never
touches settings.json, config.toml or privacy.local.toml.
"""
import difflib
import json
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path

from cli import doctor, paths, privacy

PLUGIN_ID = "kit@multi-agent-kit"
MARKETPLACE = "multi-agent-kit"
# read-only baseline, machine-wide. The space before `*` is load-bearing: `Bash(git diff*)`
# is a PREFIX match that also allows `git difftool --extcmd=<anything>` (arbitrary
# execution) and `Bash(ls*)` allows lsof/lsblk (review fix F2). Bare + ` *` forms, as v4 shipped.
BASELINE = ["Bash(git status)", "Bash(git status *)", "Bash(git diff)", "Bash(git diff *)",
            "Bash(git log)", "Bash(git log *)", "Bash(git show)", "Bash(git show *)", "Bash(ls)", "Bash(ls *)"]
# dropped on (re-)run: v4's timeout wildcard, and the space-less forms an early v5 setup wrote
DROP = ["Bash(timeout *)", "Bash(git status*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git show*)", "Bash(ls*)"]
GUARD_HOOKS = ("pre-commit", "pre-push")
# chain-only shims: with a global core.hooksPath git looks for EVERY hook in the
# shim dir, so without these the repo-local ones (git-lfs post-checkout, commit-msg
# linters, a bare repo's post-receive, …) would silently stop running.
# reference-transaction / post-index-change are left out on purpose: they fire on
# every ref update / index write, and a shim there would tax every git command.
CHAIN_HOOKS = ("applypatch-msg", "pre-applypatch", "post-applypatch", "pre-merge-commit",
               "prepare-commit-msg", "commit-msg", "post-commit", "pre-rebase", "post-checkout",
               "post-merge", "post-rewrite", "pre-auto-gc", "push-to-checkout", "sendemail-validate",
               "pre-receive", "update", "post-receive", "post-update")
HOOKS = GUARD_HOOKS + CHAIN_HOOKS


class Setup:
    def __init__(self, args):
        self.dry = args.dry_run
        self.rc = 0
        self.kit_root = paths.kit_root()
        self.cfg_dir = paths.config_dir()
        self.hooks_dir = self.cfg_dir / "git-hooks"
        self.bin_dir = paths.expand(args.bin_dir) if args.bin_dir else paths.home() / ".local" / "bin"
        self.args = args

    # ---- output / execution helpers
    def say(self, status, step, detail=""):
        print(f"[{status}] {step}" + (f" — {detail}" if detail else ""))

    def would_run(self, cmd):
        print("WOULD RUN: " + " ".join(shlex.quote(c) if c.strip() != c or " " in c else c for c in cmd))

    def would_write(self, path, what=""):
        print(f"WOULD WRITE: {path}" + (f" ({what})" if what else ""))

    def run(self, cmd, check=True):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd)} failed ({r.returncode}): {(r.stderr or r.stdout).strip()[:300]}")
        return r

    def warn(self, step, detail):
        self.say("warn", step, detail)
        self.rc = 1

    # ---- steps
    def claude_json(self, *args):
        try:
            r = self.run(["claude", *args, "--json"], check=False)
            return json.loads(r.stdout or "[]")
        except (OSError, ValueError):
            return []

    def step_plugin(self):
        step = "plugin"
        if self.args.marketplace == "github":
            owner = self.args.github_owner or paths_cfg_get("github_owner")
            if not owner:
                self.warn(step, "github marketplace needs --github-owner (or github_owner in config.toml)")
                return
            src = f"{owner}/multi-agent-starter"
        else:
            src = str(self.kit_root)
        add = ["claude", "plugin", "marketplace", "add", src]
        inst = ["claude", "plugin", "install", PLUGIN_ID, "--scope", "user"]
        if self.dry:
            self.would_run(add)
            self.would_run(inst)
            return
        if not shutil.which("claude"):
            self.warn(step, "claude not on PATH — install Claude Code, then re-run kit setup")
            return
        if any(p.get("id") == PLUGIN_ID for p in self.claude_json("plugin", "list") if isinstance(p, dict)):
            self.say("skip", step, f"{PLUGIN_ID} already installed")
            return
        if not any(m.get("name") == MARKETPLACE for m in self.claude_json("plugin", "marketplace", "list")
                   if isinstance(m, dict)):
            self.run(add)
        self.run(inst)
        self.say("done", step, f"{PLUGIN_ID} installed from {src} (user scope)")

    def step_permissions(self):
        step = "permissions"
        path = paths.claude_dir() / "settings.json"
        old_text = path.read_text() if path.is_file() else ""
        try:
            data = json.loads(old_text) if old_text.strip() else {}
        except ValueError:
            self.warn(step, f"{path} is not valid JSON — fix it, then re-run")
            return
        if not isinstance(data, dict):
            self.warn(step, f"{path} top level is not an object")
            return
        perms = data.setdefault("permissions", {})
        allow = perms.get("allow", [])
        if not isinstance(allow, list):
            self.warn(step, f"{path} permissions.allow is not a list")
            return
        new_allow = [a for a in allow if a not in DROP] + [b for b in BASELINE if b not in allow]
        if new_allow == allow and old_text:
            self.say("skip", step, "baseline present, no Bash(timeout *) / space-less wildcards")
            return
        perms["allow"] = new_allow
        new_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
        diff = "".join(difflib.unified_diff(old_text.splitlines(True), new_text.splitlines(True),
                                            str(path), str(path) + " (kit)"))
        if self.dry:
            self.would_write(path, "merge permission baseline, drop Bash(timeout *) and space-less wildcards")
            print(diff, end="")
            return
        print(diff, end="")
        path.parent.mkdir(parents=True, exist_ok=True)
        if old_text:
            shutil.copy2(path, path.with_name(f"settings.json.bak-{time.strftime('%Y%m%d-%H%M%S')}"))
        path.write_text(new_text)
        self.say("done", step, f"merged baseline into {path}")

    def step_config(self):
        step = "config.toml"
        path = paths.config_path()
        owner = self.args.github_owner
        wanted_top = [("kit_root", f'"{self.kit_root}"'), ("profile", '"full"')]
        if owner:
            wanted_top.append(("github_owner", f'"{owner}"'))
        if not path.is_file():
            body = ("# ~/.config/kit/config.toml — LOCAL ONLY (never commit). Written by `kit setup`.\n"
                    + "".join(f"{k} = {v}\n" for k, v in wanted_top)
                    + '\n[audit]\nroot    = "~"                       # same scan root as proj\n'
                    + 'exclude = []                        # fleet exclusions live HERE, never in the repo\n')
            if self.dry:
                self.would_write(path, "kit_root, profile, [audit]")
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            self.say("done", step, str(path))
            return
        text = path.read_text()
        try:
            cfg = paths.load_config()
        except Exception as e:  # malformed: never rewrite blindly
            self.warn(step, f"{path} is malformed ({e}) — fix by hand")
            return
        lines = text.splitlines(True)
        add_top = [f"{k} = {v}\n" for k, v in wanted_top if k not in cfg]
        changed = False
        if add_top:
            i = 0
            while i < len(lines) and lines[i].lstrip().startswith("#"):
                i += 1
            lines[i:i] = add_top
            changed = True
        audit = cfg.get("audit")
        if not isinstance(audit, dict):
            lines.append('\n[audit]\nroot    = "~"\nexclude = []\n')
            changed = True
        else:
            missing = [f'{k} = {v}\n' for k, v in (("root", '"~"'), ("exclude", "[]")) if k not in audit]
            if missing:
                idx = next(i for i, l in enumerate(lines) if l.strip().startswith("[audit]"))
                lines[idx + 1:idx + 1] = missing
                changed = True
        if not changed:
            self.say("skip", step, "all keys present")
            return
        if self.dry:
            self.would_write(path, "add missing keys")
            return
        path.write_text("".join(lines))
        self.say("done", step, "added missing keys")

    def shim_text(self, hook):
        return (self.kit_root / "plugin" / "guard" / "shim.sh").read_text().replace("__HOOK__", hook)

    def step_shims(self):
        step = "git-hooks shims"
        todo = [h for h in HOOKS if not ((self.hooks_dir / h).is_file()
                                          and (self.hooks_dir / h).read_text() == self.shim_text(h)
                                          and os.access(self.hooks_dir / h, os.X_OK))]
        if not todo:
            self.say("skip", step, f"{len(HOOKS)} shims up to date")
        elif self.dry:
            for h in todo:
                self.would_write(self.hooks_dir / h, "shim, mode 755")
        else:
            self.hooks_dir.mkdir(parents=True, exist_ok=True)
            for h in todo:
                p = self.hooks_dir / h
                p.write_text(self.shim_text(h))
                p.chmod(0o755)
            self.say("done", step, f"{len(todo)} shims in {self.hooks_dir}")
        # global hooksPath
        step = "core.hooksPath"
        cmd = ["git", "config", "--global", "core.hooksPath", str(self.hooks_dir)]
        if self.dry:
            self.would_run(cmd)
            return
        cur = self.run(["git", "config", "--global", "--get", "core.hooksPath"], check=False).stdout.strip()
        if cur and Path(os.path.expanduser(cur)) == self.hooks_dir:
            self.say("skip", step, cur)
        elif cur:
            self.warn(step, f"global core.hooksPath is already {cur} — not overwriting; "
                      f"unset it yourself, then re-run (the kit shims would replace those hooks)")
        else:
            self.run(cmd)
            self.say("done", step, str(self.hooks_dir))

    def step_privacy(self):
        step = "privacy.local.toml"
        p = paths.privacy_path()
        if p.is_file():
            if (p.stat().st_mode & 0o777) == 0o600:
                self.say("skip", step, "exists, mode 600")
            elif self.dry:
                self.would_run(["chmod", "600", str(p)])
            else:
                p.chmod(0o600)
                self.say("done", step, "chmod 600")
            return
        if self.dry:
            self.would_write(p, "skeleton, mode 600")
            return
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(privacy.Privacy.skeleton())
        self.say("done", step, f"skeleton at {p} (mode 600)")

    def step_symlinks(self):
        for name in ("kit", "proj"):
            step = f"symlink {name}"
            link, target = self.bin_dir / name, self.kit_root / "bin" / name
            if link.is_symlink() and Path(os.readlink(link)) == target:
                self.say("skip", step, f"{link} → {target}")
            elif link.exists() or link.is_symlink():
                self.warn(step, f"{link} exists and is not a link to {target} — left alone")
            elif self.dry:
                self.would_run(["ln", "-s", str(target), str(link)])
            else:
                self.bin_dir.mkdir(parents=True, exist_ok=True)
                link.symlink_to(target)
                self.say("done", step, f"{link} → {target}")

    def step_tools(self):
        if self.dry:
            self.would_run(["kit", "doctor", "--install", "--bin-dir", str(self.bin_dir)])
            return
        print("tools (kit doctor --install):")
        if not doctor.install_missing(self.bin_dir, log=lambda m: print("  " + m)):
            self.rc = 1

    # ---- uninstall
    def uninstall(self):
        if self.dry:
            self.would_run(["claude", "plugin", "uninstall", PLUGIN_ID, "--scope", "user"])
            self.would_run(["claude", "plugin", "marketplace", "remove", MARKETPLACE])
            self.would_run(["git", "config", "--global", "--unset", "core.hooksPath"])
        else:
            if shutil.which("claude"):
                if any(p.get("id") == PLUGIN_ID for p in self.claude_json("plugin", "list") if isinstance(p, dict)):
                    self.run(["claude", "plugin", "uninstall", PLUGIN_ID, "--scope", "user"], check=False)
                    self.say("done", "plugin", f"{PLUGIN_ID} uninstalled")
                else:
                    self.say("skip", "plugin", "not installed")
                if any(m.get("name") == MARKETPLACE for m in self.claude_json("plugin", "marketplace", "list")
                       if isinstance(m, dict)):
                    self.run(["claude", "plugin", "marketplace", "remove", MARKETPLACE], check=False)
                    self.say("done", "marketplace", f"{MARKETPLACE} removed")
            cur = self.run(["git", "config", "--global", "--get", "core.hooksPath"], check=False).stdout.strip()
            if cur and Path(os.path.expanduser(cur)) == self.hooks_dir:
                self.run(["git", "config", "--global", "--unset", "core.hooksPath"])
                self.say("done", "core.hooksPath", "unset")
            else:
                self.say("skip", "core.hooksPath", f"not ours ({cur or 'unset'})")
        for h in HOOKS:
            p = self.hooks_dir / h
            if p.exists():
                if self.dry:
                    print(f"WOULD REMOVE: {p}")
                else:
                    p.unlink()
                    self.say("done", "shim", f"removed {p}")
        if not self.dry and self.hooks_dir.is_dir() and not any(self.hooks_dir.iterdir()):
            self.hooks_dir.rmdir()
        for name in ("kit", "proj"):
            link, target = self.bin_dir / name, self.kit_root / "bin" / name
            if link.is_symlink() and Path(os.readlink(link)) == target:
                if self.dry:
                    print(f"WOULD REMOVE: {link}")
                else:
                    link.unlink()
                    self.say("done", "symlink", f"removed {link}")
        print("kept: settings.json permissions, config.toml, privacy.local.toml")
        return self.rc


def paths_cfg_get(key):
    try:
        return paths.load_config().get(key)
    except Exception:
        return None


def run(args) -> int:
    s = Setup(args)
    if args.uninstall:
        return s.uninstall()
    for step in (s.step_plugin, s.step_permissions, s.step_config, s.step_shims, s.step_privacy,
                 s.step_symlinks, s.step_tools):
        try:
            step()
        except (RuntimeError, OSError) as e:
            s.warn(step.__name__.replace("step_", ""), str(e))
    if not s.dry:
        print("next: kit doctor")
    return s.rc
