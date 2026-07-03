# [專案名]

> [一句話定位:這是什麼、給誰用。例:「我自己的 portfolio 站」]。**[私人假設,例:私人 repo,這份 README 是寫給未來的我]**——
> 隔幾個月回來能 30 秒內重啟、想起這專案怎麼運作、以及怎麼叫 AI 接手。
>
> Stack 一行:[語言/框架/主要依賴,一行列完。例:Next.js 16 · React 19 · Tailwind v4 · Supabase · Vercel]。

---

## 🚀 30 秒重啟

```bash
[安裝指令,例:npm install]
# [環境變數提醒,例:確認 .env.local 存在(見下方),沒有就從密碼管理器/hosting 平台還原]
[啟動開發伺服器指令]          # → [預設網址,例:http://localhost:3000]
```

其他指令:

| 指令 | 用途 |
|------|------|
| `[dev 指令]` | 本地開發 |
| `[build 指令]` | 生產 build |
| `[start 指令]` | 跑 build 出來的 production server |
| `[lint/test 指令]` | [quality gate 說明,例:唯一的 quality gate,沒有測試] |

## 🔑 環境變數 (`[.env 檔名,例:.env.local]`,不入 git)

| 變數 | 說明 |
|------|------|
| `[VAR_NAME]` | [說明] |

> 沒有 `[.env 檔名]` 會怎樣:[例:某功能靜默回 fallback、某頁面 500]。先補檔再 debug。

## ☁️ 部署

- Hosting:**[平台,例:Vercel / Railway / 自架]**([部署方式,例:git push 自動觸發])
- DB:**[資料庫,例:Postgres / Supabase / SQLite / 無]**([連線方式或位置])
- 資產:[圖片/檔案存放位置,例:S3 bucket / 本地 public/;無則刪除此行]

---

## 🧠 半年後最容易忘的事

> 這段隨開發累積,不是一次寫完。遇到「差點忘記」「這是刻意的不是 bug」的細節就補一條。

- [第一條地雷 / 約定]

## 📚 文件地圖

| 檔案 | 內容 |
|------|------|
| `CLAUDE.md` | AI 協作規則 + 本專案 constraints |
| `docs/ARCHITECTURE.md` | 深度技術參考(AI 後補,初期可能不存在) |
| `docs/specs/` | 功能藍圖 / spec |

---

## 🤖 叫 AI 接手

**回來第一句(複習 prompt)**
```
先讀 CLAUDE.md 和 docs/ARCHITECTURE.md(若存在),然後用三五句話跟我複習:
這個專案在做什麼、有哪些必知 constraints、目前有沒有半成品或 TODO。
先不要改任何檔案。
```

**kit 更新**(拉取 kit repo 最新的 workflow rules / templates):
```bash
~/.multi-agent-kit/init.sh . --update
```
