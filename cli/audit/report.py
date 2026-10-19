"""Audit findings and their redaction (output side lives here too — Task 3.8c)."""
import re
from dataclasses import dataclass

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO", "UNKNOWN")
RANK = {s: i for i, s in enumerate(SEVERITIES)}

TOKEN_RE = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}"
                      r"|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]+)")


@dataclass
class Finding:
    repo: str
    check: str
    severity: str
    path: str | None = None
    line: int | None = None
    snippet: str = ""
    fix: str = ""


def redact(text: str, privacy=None) -> str:
    """Literal values → <name>, configured usernames in paths → <user>, token-shaped
    strings → ***. Applied to every snippet derived from file content."""
    out = text or ""
    if privacy is not None:
        for lit in sorted(privacy.literals, key=lambda l: -len(l.value)):
            out = re.sub(re.escape(lit.value), f"<{lit.name}>", out, flags=re.IGNORECASE)
        for i, e in enumerate(privacy.emails):
            out = re.sub(re.escape(e), "<email>", out, flags=re.IGNORECASE)
        for u in privacy.usernames:
            out = re.sub(rf"(/home/|/mnt/[a-z]/Users/|[A-Za-z]:\\\\Users\\\\){re.escape(u)}(?=[/\\\\]|$)",
                         r"\1<user>", out, flags=re.IGNORECASE)
    out = TOKEN_RE.sub("***", out)
    return out


def max_severity(findings) -> str | None:
    ranked = [f.severity for f in findings if f.severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW")]
    return min(ranked, key=lambda s: RANK[s]) if ranked else None
