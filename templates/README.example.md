# portfolio-cholate

> 我自己的 portfolio 站 (cholate.dev)。**私人 repo,這份 README 是寫給未來的我**——
> 隔幾個月回來能 30 秒內重啟、想起這專案怎麼運作、以及怎麼叫 AI 接手。
>
> Stack 一行:Next.js 16 (App Router + Turbopack) · React 19 · Tailwind v4 · shadcn/ui · Supabase · GCS 圖床 · Vercel。**全 JS 無 TS**。

---

## 🚀 30 秒重啟

```bash
npm install
# 確認 .env.local 存在(見下方),沒有就從密碼管理器/Vercel 還原
npm run dev          # → http://localhost:3000  (Turbopack)
```

其他指令:

| 指令 | 用途 |
|------|------|
| `npm run dev` | 本地開發 (Turbopack) |
| `npm run build` | 生產 build (`next build --turbopack`) |
| `npm start` | 跑 build 出來的 production server |
| `npm run lint` | ESLint (**唯一的 quality gate,沒有測試**) |

## 🔑 環境變數 (`.env.local`,不入 git)

只需要這三個——值在我的密碼管理器 / Vercel project settings 裡:

| 變數 | 說明 |
|------|------|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase REST endpoint |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase anon key |
| `TOKEN` | 半私人內容的存取密碼,與 cookie `site_access` 比對 |

> 沒有 `.env.local` → Supabase 查詢會靜默回 fallback(空資料)、`/collection` 與 gallery gate 失效。先補檔再 debug。

## ☁️ 部署

- Hosting:**Vercel**(repo 內沒有 `vercel.json`,deploy hook / env 都在 Vercel 端設定好了)
- 圖片:**Google Cloud Storage** 兩個公開 bucket `cholate-gallery` / `cholate-thumbnail`(白名單在 `next.config.mjs`)
- DB:**Supabase**,4 tables (`Projects` / `Games` / `Anime` / `Milestone`) + 1 RPC `get_random_media`

---

## 🧠 半年後最容易忘的事

- **半私人內容怎麼進去**:分享一個帶 `?secret_token=<TOKEN>` 的 URL → `proxy.js`(Next 16 把 `middleware.js` 改名成這個)攔截、比對 `TOKEN`、set httpOnly cookie 7 天 → 之後 `/collection`、gallery 自動解鎖。
- **gallery 的 gate 目前是註解掉的**(`app/gallery/page.jsx`),等於對所有人開放——這是刻意的,別當 bug 修。
- **沒有測試**:任何邏輯改動(`services/`、`gallery/client.jsx`)一定要 `npm run dev` 手動跑過。
- **Tailwind 沒有 `2xl`**:斷點只到 `xl`,寫 `2xl:` 會無聲失效。
- **DB 查詢一律走 `services/portfolio.js` + `executeQuery`**,別在 component 直接 `import { supabase }`。

## 📚 想更深入時看哪裡

| 檔案 | 內容 |
|------|------|
| `CLAUDE.md` | AI 協作守則 + **本專案必知重點**(constraints) |
| `docs/ARCHITECTURE.md` | 深度技術參考:架構分層、data flow、Supabase schema、跨檔案連接圖、歷史遺留、「要改 X 先看 Y」對照表 |

---

## 🤖 叫 AI 接手的建議提示詞

這個 repo 帶了一套 multi-agent kit(`CLAUDE.md` + `.claude/`)。重啟後可以這樣開場:

**① 讓 AI 先重新熟悉專案(回來第一句)**
```
先讀 CLAUDE.md 和 docs/ARCHITECTURE.md,然後用三五句話跟我複習:
這個專案在做什麼、有哪些必知 constraints、目前有沒有半成品或 TODO。
先不要改任何檔案。
```

**② 加小功能 / 改樣式(直接做,跳過完整流程)**
```
<描述要改的東西>。這是小改動,直接做,不需要 plan。
```

**③ 加比較大的功能(走 plan → review)**
```
我想加 <功能>。請走完整流程:先 brainstorm 跟我確認 scope,
再寫 plan、跑 /codex:review,等我 approve 再實作。
```

**④ 修 bug**
```
<症狀>。請先找 root cause 再修;如果動到業務邏輯就跑 /codex:review。
```

**⑤ 環境 / kit 沒裝好時**
```bash
./setup.sh          # 檢查 claude / codex / gemini CLI 與 env
```
codex plugin 是每台機器一次性安裝(在 Claude Code 內):
```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

> kit 的完整使用手冊(prompt 範本、hooks、anti-patterns)在我的外部 kit repo 的 `USAGE.md`,不放這裡。
