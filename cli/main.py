"""kit entrypoint: argparse dispatch. Subcommand modules are imported lazily."""
import argparse
import importlib
import sys

from cli import paths

SUBCOMMANDS = {
    "setup": ("cli.setup_cmd", "one-time machine setup: plugin, permissions, git guard, tools"),
    "doctor": ("cli.doctor", "check this machine's kit install (--install fetches pinned tools)"),
    "init": ("cli.init_cmd", "scaffold a new kit v5 project"),
    "migrate": ("cli.migrate", "migrate a v4 project to v5 (dry-run unless --apply)"),
    "audit": ("cli.audit", "fleet audit: privacy, GitHub settings, workflows, deps"),
    "guard": ("cli.guard_cmd", "git guard status | bypass \"<reason>\""),
    "update": ("cli.update_cmd", "update the kit plugin (local checkout or GitHub marketplace)"),
}


class KitError(Exception):
    """User-facing failure: printed as `kit: error: <msg>`, exit 1."""


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="kit", description="multi-agent-kit v5 machine CLI")
    p.add_argument("--version", action="store_true", help="print the kit version")
    sub = p.add_subparsers(dest="cmd", metavar="{" + ",".join(SUBCOMMANDS) + "}")

    s = sub.add_parser("setup", help=SUBCOMMANDS["setup"][1])
    s.add_argument("--dry-run", action="store_true", help="print WOULD RUN / WOULD WRITE only")
    s.add_argument("--uninstall", action="store_true", help="undo plugin install, hooksPath, shims, symlinks")
    s.add_argument("--marketplace", choices=["local", "github"], default="local")
    s.add_argument("--github-owner", default=None)
    s.add_argument("--bin-dir", default=None, help="tool/symlink dir (default ~/.local/bin)")

    s = sub.add_parser("doctor", help=SUBCOMMANDS["doctor"][1])
    s.add_argument("--install", action="store_true", help="download pinned gitleaks/osv-scanner (sha256-verified)")
    s.add_argument("--bin-dir", default=None, help="install dir (default ~/.local/bin)")

    s = sub.add_parser("init", help=SUBCOMMANDS["init"][1])
    s.add_argument("dir")
    s.add_argument("--private", action="store_true")
    s.add_argument("--license", choices=["MIT", "CC-BY-4.0", "none"], default="MIT")
    s.add_argument("--lang", choices=["en", "zh-TW"], default="en")
    s.add_argument("--owner", default=None, help="LICENSE copyright holder (default: git user.name)")

    s = sub.add_parser("migrate", help=SUBCOMMANDS["migrate"][1])
    s.add_argument("dir")
    s.add_argument("--apply", action="store_true")
    s.add_argument("--commit", action="store_true", help="commit the migration (implies --apply)")
    s.add_argument("--allow-dirty", action="store_true")
    s.add_argument("--visibility", choices=["public", "private"], default=None,
                   help="override the GitHub lookup")

    s = sub.add_parser("audit", help=SUBCOMMANDS["audit"][1])
    s.add_argument("names", nargs="*")
    s.add_argument("--verbose", "-v", action="store_true")
    s.add_argument("--json", metavar="PATH", default=None)
    s.add_argument("--html", metavar="PATH", nargs="?", const="", default=None)
    s.add_argument("--baseline", metavar="PATH", default=None)
    s.add_argument("--fetch-remote", action="store_true")
    s.add_argument("--offline", metavar="DIR", default=None, help="recorded gh api fixtures (tests)")

    s = sub.add_parser("guard", help=SUBCOMMANDS["guard"][1])
    s.add_argument("action", choices=["status", "bypass"])
    s.add_argument("reason", nargs="?", default=None)

    s = sub.add_parser("update", help=SUBCOMMANDS["update"][1])
    s.add_argument("--dry-run", action="store_true")
    return p


def main(argv: list[str]) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:  # argparse: --help → 0, usage errors → 2
        return int(e.code or 0)
    if args.version:
        print(f"kit {paths.version()}")
        return 0
    if not args.cmd:
        parser.print_help(sys.stderr)
        return 2
    mod = importlib.import_module(SUBCOMMANDS[args.cmd][0])
    try:
        return int(mod.run(args) or 0)
    except KitError as e:
        print(f"kit: error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("kit: interrupted", file=sys.stderr)
        return 130
