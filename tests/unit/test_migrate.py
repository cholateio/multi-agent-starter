"""Unit tests for cli/migrate.py pure functions. Fixtures are the kit's own v4
CLAUDE.md template and v4 .claude/settings.json (no private names)."""
import json

from tests.unit._helpers import IsolatedTestCase
from cli import migrate

V4_CLAUDE_MD = '# [PROJECT NAME]\n\n> CLAUDE.md（kit v4.3）。本檔只放「這個專案是什麼」——工作流、派工、\n> review 規則由 `.claude/rules/` 自動載入（kit-owned，別在專案裡改）。\n> 首次使用：跑 `claude`，貼上 `init.sh` 結尾印出的 bootstrap prompt，\n> 讓 AI 幫你把 [佔位符] 填掉。\n\n## Project goal\n\n[一句話：這個專案是什麼、給誰用、核心目的。\n 例：「給小型團隊用的 expense tracking SaaS，優先 self-host。」]\n\n## Stack\n\n- Language: [例：Python 3.12 / TypeScript 5.4 / Go 1.22]\n- Framework: [例：FastAPI / Next.js 14 / none]\n- Datastore: [例：PostgreSQL 16 / SQLite / none]\n- Build/run: [完整指令，例：`pnpm dev` / `make run`]\n- Test: [完整指令，例：`pytest -q` / `pnpm vitest run`——弱模型會照抄\n  這一行來跑驗證，寫到可以直接複製執行的程度]\n\n## File layout\n\n[新專案：首次架構決策後填入。既有專案：貼 `tree -L 2` 並在關鍵目錄後\n 加一句用途註記。例：\n - `src/api/` — HTTP handlers，薄層，不放業務邏輯\n - `src/core/` — 業務邏輯，所有 DB writes 走 repository]\n\n## Project-specific constraints（禁區與硬規則）\n\n[本專案的不可違反規則。格式：每條一行，「路徑或範圍：規則 + 原因 +\n 替代作法」。越具體越好。例：\n - `src/legacy/payment/`：不可修改——會破壞舊金流；新需求走 `src/payment_v2/`\n - 所有 DB writes 必須走 repository pattern，不准裸 SQL\n 新專案可留空，踩到坑再累積。]\n\n**同步執法**：上面每一條「路徑型」禁區，都要把路徑同步加進\n`.claude/protected-paths`（一行一個 glob，`*` 會跨目錄層級，\n`src/legacy/` 結尾斜線代表整棵子樹）——PreToolUse hook 會物理擋下\n對這些路徑的編輯，不再只靠模型自律。放寬或刪除任何一條需要 user\n明確同意（見 kit-evolution 規則）。\n\n## 檔案路由（需要時才讀，不用背）\n\n| 情境 | 讀這裡 |\n|------|--------|\n| 卡關了 / 想宣告完成 / 猶豫要不要問 user | `.claude/docs/judgment-matrix.md` |\n| 要派工給 subagent | `/kit-dispatch` skill（五種模板） |\n| 要記教訓 / 查歷史教訓 / 想改 harness 檔案 | `docs/LESSONS.md`（append；動大手術前先掃一眼）/ kit-evolution 規則（自動已載入） |\n| 有 spec 的功能 | `docs/specs/`（spec 是需求的唯一權威來源） |\n| 要做 UI / 設計 schema / 同一 bug 連續卡 / 引入外部服務 / 定架構 | `.claude/docs/verification-signals.md`（命中哪節讀哪節） |\n\n（review / isolation / 任務 sizing / 派工升降級 / 判斷層的規則不在\n本檔——`.claude/rules/` 的 kit-workflow、kit-delegation、kit-evolution、\nkit-judgment 已自動載入每個 session，直接遵守即可。）\n'

V4_SETTINGS_JSON = '{\n  "_comment": "kit settings template (v4.0). permissions.allow ships ACTIVE with read-only commands so review/research subagents don\'t spam permission prompts — trim or extend to taste. Hooks ship ENABLED (v3.5+): to disable, rename \'hooks\' to something else (e.g. \'_hooks_disabled\') and restart the session. Keep SessionStart and Stop TOGETHER — the Stop gate reads the baseline that SessionStart records; without it, committed changes are invisible to the gate. v4.0 adds protect-paths (no-touch-zone enforcement; user escape hatch: launch with KIT_PROTECT=off) and tool-breaker (retry-spiral circuit breaker + telemetry; KIT_BREAKER=off), registered under PreToolUse/PostToolUseFailure below. v4.8: the Stop gate is turn-scoped — it fires only on turns that changed the working tree, so brainstorming/read-only turns no longer trip it — and gains its own user escape hatch, KIT_REVIEW_GATE=off, to disable the final-review gate for a session.",\n\n  "permissions": {\n    "allow": [\n      "Bash(timeout *)",\n      "Bash(git status)",\n      "Bash(git status *)",\n      "Bash(git diff)",\n      "Bash(git diff *)",\n      "Bash(git log)",\n      "Bash(git log *)",\n      "Bash(git show *)",\n      "Bash(ls)",\n      "Bash(ls *)"\n    ]\n  },\n\n  "hooks": {\n    "PreToolUse": [\n      {\n        "matcher": "Edit|MultiEdit|Write|NotebookEdit",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/protect-paths.sh",\n            "timeout": 5\n          }\n        ]\n      },\n      {\n        "matcher": "*",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/tool-breaker.sh",\n            "timeout": 5\n          }\n        ]\n      }\n    ],\n    "PostToolUseFailure": [\n      {\n        "matcher": "*",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/tool-breaker.sh",\n            "timeout": 5\n          }\n        ]\n      }\n    ],\n    "SessionStart": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh",\n            "timeout": 5\n          }\n        ]\n      }\n    ],\n    "UserPromptSubmit": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/classify-task.sh",\n            "timeout": 5\n          }\n        ]\n      }\n    ],\n    "Stop": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/verify-final-review.sh",\n            "timeout": 10\n          }\n        ]\n      }\n    ]\n  }\n}\n'

MIRRORED = "Path-type constraints above are mirrored in `kit.toml [protected]` (the PreToolUse hook enforces them)."


def section(text, heading):
    start = text.index(heading)
    nxt = text.find("\n## ", start + 1)
    return text[start:nxt if nxt != -1 else len(text)]


class TestSplitClaudeMd(IsolatedTestCase):
    def test_v4_template_split(self):
        agents, stub, review = migrate.split_claude_md(V4_CLAUDE_MD)
        self.assertFalse(review)
        self.assertIn("## Project goal", agents)
        self.assertNotIn("檔案路由", agents)
        self.assertNotIn("CLAUDE.md（kit v4", agents)
        self.assertNotIn("**同步執法**", agents)
        self.assertIn(MIRRORED, agents)
        # constraints body carried verbatim (everything before the 同步執法 paragraph)
        orig = section(V4_CLAUDE_MD, "## Project-specific constraints")
        orig_body = orig.split("**同步執法**")[0].rstrip()
        self.assertIn(orig_body, agents)
        for h in ("## Stack", "## File layout"):
            self.assertIn(section(V4_CLAUDE_MD, h).rstrip(), agents)
        self.assertTrue(agents.startswith("# [PROJECT NAME]\n"))
        self.assertNotIn("\n\n\n", agents)
        self.assertTrue(stub.startswith("@AGENTS.md\n"))
        self.assertNotIn("non-template", stub)

    def test_no_markers_needs_review_and_loses_nothing(self):
        text = "# thing\n\n## Goal\n\nDo stuff.\n"
        agents, stub, review = migrate.split_claude_md(text)
        self.assertTrue(review)
        self.assertEqual(agents, text)
        self.assertTrue(stub.startswith("@AGENTS.md"))

    def test_multi_agent_kit_heading_variant_and_extra_sections(self):
        text = ("# p\n\n> CLAUDE.md（kit 版本見 `.claude/kit-version`）。本檔只放專案內容；\n> 路由表。\n\n"
                "## Project goal\n\nG.\n\n## Coding standards\n\nUse tabs.\n\n"
                "## Project-specific constraints（禁區與硬規則）\n\n（目前無；路徑型禁區同步加進 `.claude/protected-paths`。）\n\n"
                "## Multi-agent kit\n\nworkflow ...\n\n| a | b |\n|---|---|\n| x | y |\n")
        agents, stub, review = migrate.split_claude_md(text)
        self.assertFalse(review)
        self.assertNotIn("Multi-agent kit", agents)
        self.assertNotIn("> CLAUDE.md", agents)
        self.assertIn("## Coding standards\n\nUse tabs.", agents)
        self.assertIn("`kit.toml [protected]`", agents)       # v4 path reference renamed
        self.assertNotIn(".claude/protected-paths", agents)
        self.assertIn('"Coding standards"', stub)               # listed, not duplicated
        self.assertNotIn("Use tabs.", stub)

    def test_kit_routing_heading_variant_mid_file(self):
        text = "# p\n\n## What\n\nW.\n\n## Kit routing (multi-agent kit)\n\nrows\n\n## Related repos\n\nR.\n"
        agents, _, review = migrate.split_claude_md(text)
        self.assertFalse(review)
        self.assertEqual(agents, "# p\n\n## What\n\nW.\n\n## Related repos\n\nR.\n")

    def test_is_stub(self):
        _, stub, _ = migrate.split_claude_md(V4_CLAUDE_MD)
        self.assertTrue(migrate.is_stub(stub))
        self.assertFalse(migrate.is_stub(V4_CLAUDE_MD))


class TestProtected(IsolatedTestCase):
    def test_comments_kept_globs_listed(self):
        items, rejected = migrate.protected_from_v4("# legacy\nsrc/legacy/*\n\n  supabase/migrations/  \n")
        self.assertEqual(items, ["# legacy", "src/legacy/*", "supabase/migrations/"])
        self.assertEqual(rejected, [])

    def test_trailing_comment_split_like_v4_hook(self):
        # v4 protect-paths stripped everything after '#' (pat="${pat%%#*}")
        items, rejected = migrate.protected_from_v4("books/*.pdf           # raw scans, never edit\nsrc/x/#y\n")
        self.assertEqual(items, ["# raw scans, never edit", "books/*.pdf", "# y", "src/x/"])
        self.assertEqual(rejected, [])

    def test_absolute_paths_rejected(self):
        items, rejected = migrate.protected_from_v4("/ho" "me/testuser/notes/\n~/x\nC:\\Users\\t\\y\nok/*\n")
        self.assertEqual(items, ["ok/*"])
        self.assertEqual(len(rejected), 3)

    def test_render_kit_toml(self):
        t = migrate.render_kit_toml("public", "MIT", ["# legacy", "src/legacy/*"])
        self.assertIn('visibility = "public"', t)
        self.assertIn("  # legacy\n", t)
        self.assertIn('  "src/legacy/*",\n', t)


class TestStripSettings(IsolatedTestCase):
    def test_v4_settings_plus_custom(self):
        s = json.loads(V4_SETTINGS_JSON)
        s["permissions"]["allow"].append("Bash(pnpm *)")
        self.assertEqual(migrate.strip_kit_settings(s), {"permissions": {"allow": ["Bash(pnpm *)"]}})

    def test_v4_settings_pure_kit_is_none(self):
        self.assertIsNone(migrate.strip_kit_settings(json.loads(V4_SETTINGS_JSON)))

    def test_user_hook_and_keys_survive(self):
        s = json.loads(V4_SETTINGS_JSON)
        s["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "notify-send done"}]})
        s["model"] = "opus"
        out = migrate.strip_kit_settings(s)
        self.assertEqual(out["model"], "opus")
        self.assertEqual(list(out["hooks"]), ["Stop"])
        self.assertEqual(out["hooks"]["Stop"][0]["hooks"][0]["command"], "notify-send done")
        self.assertNotIn("permissions", out)

    def test_owner_hook_under_claude_hooks_survives(self):
        s = json.loads(V4_SETTINGS_JSON)
        s["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [
            {"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/block-prod-deploy.sh"}]})
        out = migrate.strip_kit_settings(s)
        self.assertIsNotNone(out)
        self.assertEqual(out["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
                         "$CLAUDE_PROJECT_DIR/.claude/hooks/block-prod-deploy.sh")

    def test_merge_into_local(self):
        local = {"permissions": {"allow": ["Bash(npm test)"]}, "model": "sonnet"}
        resid = {"permissions": {"allow": ["Bash(pnpm *)", "Bash(npm test)"], "deny": ["Read(.env)"]}, "model": "opus"}
        m = migrate.merge_settings(local, resid)
        self.assertEqual(m["permissions"]["allow"], ["Bash(npm test)", "Bash(pnpm *)"])
        self.assertEqual(m["permissions"]["deny"], ["Read(.env)"])
        self.assertEqual(m["model"], "sonnet")   # local wins

    def test_migration_never_widens_permissions(self):
        """Review fix F2: the v4 → settings.local.json merge only carries the owner's own
        entries (never the v4 baseline, never a new entry), and the v5 machine-wide
        baseline has no space-less wildcard (`git diff*` would cover `git difftool`)."""
        import re
        from cli import setup_cmd
        data = json.loads(V4_SETTINGS_JSON)
        data["permissions"]["allow"].append("Bash(pnpm test)")
        resid = migrate.strip_kit_settings(data)
        local = {"permissions": {"allow": ["Bash(npm test)"]}}
        merged = migrate.merge_settings(local, resid)
        self.assertEqual(merged["permissions"]["allow"], ["Bash(npm test)", "Bash(pnpm test)"])
        wide = [b for b in setup_cmd.BASELINE if re.search(r"[^ ]\*\)$", b)]
        self.assertEqual(wide, [])
        v4 = set(migrate.V4_BASELINE) | {b.replace(" *)", ")") for b in migrate.V4_BASELINE}
        for b in setup_cmd.BASELINE:   # nothing beyond v4's read-only set (bare forms included)
            self.assertIn(b, v4)


class TestGitignoreV4Block(IsolatedTestCase):
    def test_remove_v4_tracked_on_purpose_block(self):
        text = ("node_modules/\n\n# Claude Code runtime state. `.claude/` itself IS tracked on purpose:\n"
                "# kit-owned files are regenerable via `init.sh --update`, but settings.json\n"
                "# zones) are project truth that nothing can rebuild.\n"
                ".claude/settings.local.json\n.claude/scheduled_tasks.lock\n\n*.log\n")
        out = migrate.remove_v4_gitignore_block(text)
        self.assertEqual(out, "node_modules/\n\n*.log\n")
        self.assertEqual(migrate.remove_v4_gitignore_block(out), out)
