---
name: pr-review
description: "GitHub/GitCode PR/Commit 自动 review 技能。解析 PR 或 Commit URL，获取 diff，生成结构化 comment.rktd 和可执行 send-comment.rkt 脚本。支持交互式逐条确认后发送评论。支持创建 GitHub Issue。"
user-invocable: true
argument: "<URL> [--mode report|inline|reply|issue] [--interactive]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch, Agent
---

# PR / Commit Review

对 GitHub/GitCode Pull Request 或 Commit 执行自动化代码审查，生成结构化评论文件和发送脚本。

## 核心原则

**Agent 默认只生成 `comment.rktd`，绝不主动执行 `send-comment.rkt` 发送。** 用户必须明确要求发送（如"发送"、"提交"、"执行"、"关掉这个 issue"等含有执行意图的指令）时，agent 才可调用 `send-comment.rkt`。若用户意图不明确，agent 应生成文件后告知用户可用的发送命令，由用户自行决定是否执行。

## 触发条件

用户执行 `/pr-review <URL> [--mode <mode>] [--interactive]`。

URL 可以是 PR 或 Commit 链接。

## 执行模式

通过 `--mode` 指定，默认 `inline`。

### `--mode report`（报告模式）

生成**一条**完整的 review report 作为 decision body。适合正式审查、需要结构化输出的场景。

输出特征：
- decision body 是完整报告，包含：总评、按类别分组的发现（安全/正确性/性能/风格）、具体规则引用、修复建议
- 不生成或仅生成极少量 inline-comment（仅 critical 级别）
- PR 模式：event 根据报告结论设置（`APPROVE` / `REQUEST_CHANGES` / `COMMENT`）
- Commit 模式：decision body 作为单条总结评论发送

### `--mode inline`（行评论模式，默认）

生成**简短 decision** + **多条 inline-comment**。适合轻量代码审查、逐行讨论细节。

输出特征：
- decision body 简短（1-3 句总结）
- 主要内容在 inline-comment 中，每条针对具体代码行
- 覆盖多个文件、多个 severity 级别
- 数量受 `max-inline-comments` 控制（默认 20）

### `--mode reply`（回复模式）

阅读已有评论，生成**回复**。适合回应他人 review 意见、质疑、或消极评价。

输出特征：
- 不生成 decision 和 inline-comment
- 仅生成 reply 记录，针对已有评论逐条回复
- 默认进入 `--interactive` 模式，与用户讨论每条回复的措辞和策略
- 对消极/质疑性评论：先分析评论是否有道理，再建议回复策略（接受/反驳/澄清）
- 用户可指定回复原则（如"礼貌但坚持"、"承认问题并说明计划"）

交互流程：
1. 列出所有已有评论，按时间或严重程度排序
2. 对每条评论提示：`[r]eply [s]kip [d]iscuss > `
3. `discuss`：与用户讨论该评论的上下文和最佳回复策略后再生成回复
4. 所有评论处理完毕后生成 comment.rktd

### `--mode issue`（Issue 创建模式）

在仓库中创建 GitHub/GitCode Issue。可独立使用，也可在 review 过程中混合使用。

输出特征：
- 不生成 decision 和 inline-comment
- 生成 issue 记录，每条对应一个待创建的 Issue
- 支持设置 title、body、labels、assignees、milestone
- `--interactive` 模式下逐条确认 issue 内容后再发送

独立使用：
```bash
/pr-review --mode issue https://github.com/owner/repo
```

Agent 根据用户描述生成 `comment.rktd`（`review-type: issue`）。用户确认后可通过 `send-comment.rkt` 发送。

混合使用：在 PR review 的 `comment.rktd` 中混入 `(section . issue)` 记录，实现"review 时顺便提 issue"。`send-comment.rkt` 会在发送 review 后依次创建 issue。

URL 格式：
- 独立模式：`https://github.com/<owner>/<repo>`（仅需仓库地址）
- 混合模式：沿用 PR/Commit URL，issue 记录附加在同一 `comment.rktd` 中

## 输入解析

从参数中提取 URL、模式和可选 flags：

1. 提取 `--mode`：`report` | `inline`（默认）| `reply` | `issue`
2. 提取 `--interactive`：reply 模式默认开启，其他模式手动开启
3. 解析 URL hostname 识别平台：
   - `github.com` → platform `github`
   - `gitcode.com` / `atomgit.com` → platform `gitcode`
   - 其他 → 尝试作为 GitHub Enterprise 处理
4. 从 URL path 识别类型并提取字段：
   - **PR**：`/<owner>/<repo>/pull/<number>` → `review-type: pr`
   - **PR (GitCode)**：`/<owner>/<repo>/pull/<number>` → `review-type: pr`
   - **Commit**：`/<owner>/<repo>/commit/<sha>` → `review-type: commit`
   - **Repo**（issue 模式）：`/<owner>/<repo>` → `review-type: issue`
5. 若解析失败，报错并终止

## 路径约定

本 SKILL 的脚本和参考文件位于 SKILL 安装目录下（即 `SKILL.md` 所在目录），**不一定是当前工作目录**。引用脚本时必须使用 SKILL 目录的绝对路径。

在本文档中，`$SKILL_DIR` 代表 SKILL 安装目录。agent 执行时应从 SKILL.md 的 `Base directory` 获取该路径。

## 数据获取

统一使用 `$SKILL_DIR/scripts/fetch-diff.rkt`。该脚本内部处理认证和平台差异，agent 只需调用命令行：

```bash
# 元数据摘要（人类可读）
racket $SKILL_DIR/scripts/fetch-diff.rkt --url <URL> --output summary

# 已有评论列表（含 id、type、discussion_id）
racket $SKILL_DIR/scripts/fetch-diff.rkt --url <URL> --output comments

# 变更文件列表
racket $SKILL_DIR/scripts/fetch-diff.rkt --url <URL> --output files

# 原始 unified diff
racket $SKILL_DIR/scripts/fetch-diff.rkt --url <URL> --output diff

# 完整 JSON（供程序消费，默认）
racket $SKILL_DIR/scripts/fetch-diff.rkt --url <URL> --output json
```

按需选择 `--output` 模式，避免拉取全量 JSON 后再用外部脚本解析。

### 底层 API 端点（参考）

`fetch-diff.rkt` 内部调用的端点见 `references/api-reference.md`。agent 不直接调用这些 API——统一通过脚本访问。

## 加载配置

从**使用方项目**的根目录加载（不存在则初始化）：

1. 检查项目根目录是否存在 `.skill.pr-review.history/` 目录
2. 若不存在，创建 `.skill.pr-review.history/` 并从本 skill 的 `examples/config-example.rktd` 复制为 `.skill.pr-review.history/config.rktd`，同时创建 `.skill.pr-review.history/history/`
3. 加载：
   - `.skill.pr-review.history/config.rktd` — review 规则和平台配置
   - `.skill.pr-review.history/preferences.rktd` — 用户偏好（severity 接受率、风格偏好），可能不存在
   - `.skill.pr-review.history/history/` — 最近 3 条同仓库历史 review，用于保持一致性

注意：`.skill.pr-review.history/` 是 per-project 运行时目录，不属于本 skill 仓库。

参考 `references/rktd-schemas.md` 了解完整 schema。

## 分析流程

### 通用步骤（所有模式）

1. **跳过判断**：检查 `preferences.rktd` 中 `ignore-paths`，跳过 vendor/generated 等目录
2. **阅读已有评论**：分析 fetch-diff 获取的已有评论（`review-comments`、`issue-comments`、`comments`），了解他人已指出的问题

### report 模式

3. 对所有 changed file 进行全面分析，按类别归纳发现
4. 撰写结构化报告作为 decision body，包含：
   - 总体评价（1-2 句）
   - 按类别分组的发现列表（引用文件和行号）
   - 修复建议和优先级
5. 仅为 critical 级别发现生成 inline-comment（可选，≤3 条）
6. 设置 event（PR 模式）

### inline 模式（默认）

3. **规则匹配**：将 diff hunk 与 `config.rktd` 中 `(section . rule)` 记录匹配
4. **严重级别调整**：参考 `preferences.rktd` 中 `severity-stats`：
   - 若某 severity 的 `accept-rate` < 0.2，减少该级别评论数量
   - 若 `accept-rate` > 0.8，可适当增加
5. **评论生成**：为每个发现生成 inline-comment 记录
6. **数量控制**：总评论数不超过 `config.rktd` 中 `max-inline-comments`（默认 20）
7. 生成简短 decision body（1-3 句总结）

### reply 模式

3. 列出所有已有评论，分析每条评论的意图（提问/建议/批评/赞同）
4. 进入交互流程（默认 `--interactive`），逐条处理：
   - 展示原评论内容、作者、位置
   - 分析评论是否合理，建议回复策略
   - 用户选择 `[r]eply [s]kip [d]iscuss`
   - `discuss`：与用户深入讨论后再生成回复
5. 仅生成 reply 记录，不生成 decision 和 inline-comment

### 已有评论处理

fetch-diff 返回的 JSON 中包含已有评论数据：
- PR：`review-comments`（inline）+ `issue-comments`（会话级）
- Commit：`comments`

分析时：
1. **展示给用户**：在输出摘要中列出已有评论的数量和关键内容
2. **避免重复**：若已有评论指出的问题与 agent 发现相同，不重复生成
3. **生成回复**：当用户明确要求回复某条评论（通过 `--interactive` 或自然语言指令）时，生成 `(section . reply)` 记录。Agent 也可主动建议回复——如纠正他人错误评论、补充信息等——但默认不自动生成回复，需用户确认
4. **comment ID**：每条已有评论都有 `id` 字段，作为 reply 记录的 `in-reply-to` 值

### 评论质量要求

- 每条评论必须**具体**——引用代码行，说明问题和修复方案
- `critical` 和 `warning` 必须包含修复建议或代码示例
- `suggestion` 和 `nitpick` 可简要说明
- 避免纯风格偏好评论（除非 config 中明确配置了相关 rule）
- 评论语言：与 PR 内容的主要语言一致（中文项目用中文评论）

## 生成 comment.rktd

在项目根目录生成 `comment.rktd`。每条记录使用**多行缩进格式**，记录间空行分隔，关键闭括号加注释辅助匹配。

`read-all` 天然支持多行 S-expression，无需单行压缩。

### PR review 格式

```racket
;; ── meta ──
((section . meta)
 (review-type . pr)
 (pr-url . "https://github.com/owner/repo/pull/42")
 (platform . github)
 (owner . "owner")
 (repo . "repo")
 (pr-number . 42)
 (pr-title . "PR title here")
 (pr-author . "alice")
 (reviewed-at . "2026-03-19T10:30:00Z")
) ;; end meta

;; ── decision ──
((section . decision)
 (event . "REQUEST_CHANGES")   ; "APPROVE" | "REQUEST_CHANGES" | "COMMENT"
 (body . "Overall summary of the review...")
) ;; end decision

;; ── inline #1 ──
((section . inline-comment)
 (id . 1)
 (path . "src/foo.rs")
 (line . 45)
 (position . 12)
 (side . "RIGHT")
 (body . "具体评论内容...")
 (severity . critical)
 (category . security)
 (rule-ref . "no-sql-injection")
) ;; end inline #1
```

### Commit review 格式

```racket
;; ── meta ──
((section . meta)
 (review-type . commit)
 (commit-url . "https://github.com/owner/repo/commit/abc1234")
 (platform . github)
 (owner . "owner")
 (repo . "repo")
 (commit-sha . "abc1234def5678...")
 (commit-message . "Fix something")
 (commit-author . "bob")
 (reviewed-at . "2026-03-19T10:30:00Z")
) ;; end meta

;; ── decision（commit 可选；若提供，body 作为总结评论单独发送）──
((section . decision)
 (body . "Overall summary of the commit review...")
) ;; end decision

;; ── inline #1 ──
((section . inline-comment)
 (id . 1)
 (path . "src/foo.rs")
 (line . 12)
 (position . 5)
 (side . "RIGHT")
 (body . "具体评论内容...")
 (severity . warning)
 (category . correctness)
 (rule-ref . #f)
) ;; end inline #1
```

### reply 记录（回复已有评论）

```racket
;; ── reply #1 ──
((section . reply)
 (id . 1)
 (in-reply-to . 123456789)
 (comment-type . review-comment)  ; review-comment | issue-comment | commit-comment
 (body . "回复内容...")
 (context . "原评论摘要（仅供阅读，不发送）")
) ;; end reply #1
```

- `in-reply-to`：目标评论的 API comment ID（从获取的已有评论中提取）
- `comment-type`：决定使用哪个 API 端点发送回复
  - `review-comment`：PR inline 代码评论。GitHub 使用 `in_reply_to` 字段回复；GitCode 使用 `discussion-id` 通过 discussions 端点回复
  - `issue-comment`：PR 会话级评论，直接发新 issue comment
  - `commit-comment`：Commit 评论，直接发新 commit comment
- `discussion-id`：GitCode 专用字段，从 PR 评论的 `discussion_id` 获取。GitCode 回复必需，GitHub 可省略
- `context`：引用原评论内容摘要，方便用户阅读时理解上下文，发送时忽略

### issue 记录（创建 Issue）

```racket
;; ── issue #1 ──
((section . issue)
 (id . 1)
 (title . "Issue 标题")
 (body . "Issue 正文内容，支持 Markdown")
 (labels . ("bug" "priority/high"))
 (assignees . ("alice"))
 (milestone . #f)
 (source-context . "从 PR #42 review 中发现")
) ;; end issue #1
```

- `title`：Issue 标题（必填）
- `body`：Issue 正文，支持 Markdown（必填）
- `labels`：标签列表，Racket list of strings（可选，默认空）
- `assignees`：指派人列表（可选，默认空）
- `milestone`：里程碑编号（integer）或 `#f`（可选）
- `source-context`：来源上下文说明（仅供阅读，不发送到 API）

### issue-update 记录（更新/关闭已有 Issue）

```racket
;; ── issue-update #1 ──
((section . issue-update)
 (id . 1)
 (issue-number . 1)
 (state . closed)
 (state-reason . completed)
) ;; end issue-update #1
```

- `issue-number`：目标 Issue 编号（必填）
- `state`：目标状态 `open` | `closed`（可选）
- `state-reason`：关闭原因 `completed` | `not_planned` | `reopened`（可选，仅 GitHub 支持）
- `title`：新标题（可选，不提供则不修改）
- `body`：新正文（可选，不提供则不修改）
- `labels`：新标签列表（可选，提供时**覆盖**原有标签）
- `assignees`：新指派人列表（可选，提供时**覆盖**原有指派人）

API：`PATCH /repos/{owner}/{repo}/issues/{issue_number}`

### 格式规范

- 每个 key-value pair 独占一行，1 空格缩进
- 记录末尾 `)` 独占一行，跟 `;; end <section>` 注释
- 记录间空一行，用 `;; ── section ──` 分隔头
- `body` 值中的换行用 `\n` 转义（Racket `read` 会还原）
- **不要**单行压缩——可读性优先

### 字段说明

**meta 通用字段**：`review-type`（`pr` | `commit` | `issue`）、`mode`（`report` | `inline` | `reply` | `issue`）、`platform`、`owner`、`repo`、`reviewed-at`/`created-at`
**meta PR 专有**：`pr-url`、`pr-number`、`pr-title`、`pr-author`
**meta commit 专有**：`commit-url`、`commit-sha`、`commit-message`、`commit-author`
**meta issue 专有**：无额外字段（仅需通用字段中的 `owner`、`repo`、`platform`）

**decision**：
- PR：必须提供，`event` 为 `"APPROVE"` | `"REQUEST_CHANGES"` | `"COMMENT"`
- Commit：可选，仅含 `body`（无 `event`），作为总结评论发送

**inline-comment**：
- `line`：文件行号（新文件中的行号）+ `side`（`"RIGHT"` / `"LEFT"`）。GitHub `/reviews` API 使用此字段
- `position`：diff 中从 `@@` hunk header 之后第 1 行开始计数的行偏移。GitCode `/comments` API 使用此字段。agent 生成评论时必须根据 diff 数据计算此值
- `severity`：`critical` | `warning` | `suggestion` | `nitpick`
- `category`：`security` | `correctness` | `performance` | `style` | `docs`
- `rule-ref`：关联 config.rktd 规则 id，或 `#f`

**position 计算方法**：从 `fetch-diff.rkt --output json` 返回的 files 数组中取每个文件的 diff 字段，`@@` 行之后的每一行（包括 context、`+`、`-` 行）从 1 开始计数。多个 hunk 时 position 在各 hunk 间连续累加。

## 发送（仅在用户明确要求时）

生成 `comment.rktd` 后，**告知用户**可通过以下命令发送，但 **agent 不主动执行**，除非用户明确表达了发送意图：
```bash
racket $SKILL_DIR/scripts/send-comment.rkt                    # 交互式发送
racket $SKILL_DIR/scripts/send-comment.rkt --dry-run          # 仅预览 API 调用
racket $SKILL_DIR/scripts/send-comment.rkt --non-interactive  # 直接全部发送
racket $SKILL_DIR/scripts/send-comment.rkt --skip-nitpicks    # 跳过 nitpick 级别
```

## 存档

将 `comment.rktd` 复制到 `.skill.pr-review.history/history/` 下：
- PR：`<pr-number>-<timestamp>.rktd`
- Commit：`<sha-prefix-7>-<timestamp>.rktd`

## 输出摘要

完成后打印（按模式调整）：

### report 模式
```
## Review 完成（report 模式）

**目标**: owner/repo#42 — "PR title"
**决策**: REQUEST_CHANGES
**报告**: 包含 N 项发现（M critical, K warning, ...）

### 文件
- `comment.rktd` — 报告数据（可编辑后再发送）
```

### inline 模式（默认）
```
## Review 完成（inline 模式）

**目标**: owner/repo#42 — "PR title"
**决策**: COMMENT（简短总结）
**评论统计**: 3 critical, 5 warning, 2 suggestion, 1 nitpick

### 文件
- `comment.rktd` — 评论数据（可编辑后再发送）
```

### reply 模式
```
## Reply 完成

**目标**: owner/repo#42 — "PR title"
**回复统计**: N 条回复（已跳过 M 条）

### 文件
- `comment.rktd` — 回复数据（可编辑后再发送）
```

### issue 模式
```
## Issue 创建完成

**目标**: owner/repo
**Issue 统计**: N 条 issue 已创建

### 文件
- `comment.rktd` — issue 数据（可编辑后再发送）
```

通用使用方式：
```bash
racket $SKILL_DIR/scripts/send-comment.rkt                    # 交互式发送
racket $SKILL_DIR/scripts/send-comment.rkt --dry-run          # 仅预览 API 调用
racket $SKILL_DIR/scripts/send-comment.rkt --non-interactive  # 直接全部发送
```

## 交互模式（--interactive）

`--interactive` 在 reply 模式下默认开启，其他模式手动开启。

### report / inline 模式的交互

逐文件与用户讨论：

1. 显示文件 diff 摘要
2. 列出该文件的待评论列表
3. 用户可选择：保留 / 删除 / 修改每条评论
4. 全部文件处理完毕后再生成最终 comment.rktd

### reply 模式的交互

逐条已有评论与用户讨论：

1. 展示原评论（作者、内容、位置）
2. 分析评论意图和合理性，建议回复策略
3. 用户选择：
   - `[r]eply`：采纳建议的回复（或用户提供自定义回复）
   - `[s]kip`：跳过此评论
   - `[d]iscuss`：深入讨论——用户可说明回复原则（如"承认问题但解释权衡"、"礼貌拒绝并给出理由"），agent 据此调整回复措辞
4. 对消极/攻击性评论，agent 主动建议降温策略
5. 全部处理完毕后生成 comment.rktd

使用 AskUserQuestion 工具实现交互。

## 偏好学习

每次 review 完成后（send-comment.rkt 执行后），更新 `.skill.pr-review.history/preferences.rktd`：

- 统计用户在交互模式中 accept/skip 的比率，按 severity 更新 `severity-stats`
- 记录用户手动编辑评论的模式，更新 `style-preference`
- 按仓库记录 focus-areas 和 ignore-paths

## 认证

**禁止事项**：Agent 绝对不得读取 `.github.token`、`.gitcode.token` 或任何 token 文件。认证仅由 `send-comment.rkt` 脚本在用户主动执行时处理。

Agent 获取 PR 数据时仅使用以下方式：
- `gh api ...`（依赖 gh CLI 自身的认证状态）
- `WebFetch`（公开可访问的 PR）

`send-comment.rkt` 脚本的认证查找优先级：
1. 环境变量：`GITHUB_TOKEN` / `GITCODE_TOKEN`
2. 项目目录下 `.github.token`（GitCode 同理 `.gitcode.token`）
3. `~/.github.token`（GitCode 同理 `~/.gitcode.token`）
4. Fallback：`gh auth token`（仅 GitHub）

Token 文件应为纯文本，内容仅含 token 字符串。建议加入 `.gitignore`。

## 脚本语言约束

所有 ad-hoc 脚本和数据处理代码必须使用 **Racket** 编写。禁止使用 Python 或其他语言进行中间数据处理（如 JSON 解析、格式转换等）。常用操作应优先集成到 `fetch-diff.rkt` 的 `--output` 模式中，避免管道拼接。

## 错误处理

- URL 格式无效 → 报错并给出正确格式示例
- `gh` 不可用且无 token → 提示安装 gh 或设置 GITHUB_TOKEN
- PR 不存在或无权限 → 显示 API 错误信息
- diff 过大（>100 files）→ 警告并只处理前 50 个文件

## 参考文件

以下文件均位于 `$SKILL_DIR/` 下：

- `references/rktd-schemas.md` — comment/config/preferences 完整 schema
- `references/api-reference.md` — GitHub/GitCode API 端点
- `examples/comment-example.rktd` — PR review 输出示例
- `examples/commit-comment-example.rktd` — Commit review 输出示例
- `examples/config-example.rktd` — 配置示例
- `examples/preferences-example.rktd` — 偏好示例
- `scripts/fetch-diff.rkt` — 数据获取脚本
- `scripts/send-comment.rkt` — 评论发送脚本
