---
name: pr-review
description: "GitHub/GitCode PR 自动 review 技能。解析 PR URL，获取 diff，生成结构化 comment.rktd 和可执行 send-comment.rkt 脚本。支持交互式逐条确认后发送评论。"
user-invocable: true
argument: "<PR-URL> [--interactive]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch, Agent
---

# PR Review

对 GitHub/GitCode Pull Request 执行自动化代码审查，生成结构化评论文件和发送脚本。

## 触发条件

用户执行 `/pr-review <URL>` 或 `/pr-review <URL> --interactive`。

## 输入解析

从参数中提取 PR URL 和可选 flags：

1. 解析 URL hostname 识别平台：
   - `github.com` → platform `github`
   - `gitcode.com` → platform `gitcode`
   - 其他 → 尝试作为 GitHub Enterprise 处理
2. 从 URL path 提取 `owner`、`repo`、`pr-number`
   - GitHub 格式：`/<owner>/<repo>/pull/<number>`
   - GitCode 格式：`/<owner>/<repo>/merge_requests/<number>`
3. 若解析失败，报错并终止

## 数据获取

### GitHub

优先使用 `gh` CLI（已认证，无需额外 token）：

```bash
# PR 元数据
gh api repos/{owner}/{repo}/pulls/{pr-number}

# PR diff（raw 格式）
gh api repos/{owner}/{repo}/pulls/{pr-number} -H "Accept: application/vnd.github.v3.diff"

# PR 文件列表
gh api repos/{owner}/{repo}/pulls/{pr-number}/files --paginate
```

若 `gh` 不可用，fallback 到 WebFetch + `GITHUB_TOKEN`。

### GitCode

使用 WebFetch 调用 REST API：
```
GET {api-base}/repos/{owner}/{repo}/pulls/{pr-number}
GET {api-base}/repos/{owner}/{repo}/pulls/{pr-number}/files
```

## 加载配置

从**使用方项目**的根目录加载（不存在则初始化）：

1. 检查项目根目录是否存在 `reviews/` 目录
2. 若不存在，创建 `reviews/` 并从本 skill 的 `examples/config-example.rktd` 复制为 `reviews/config.rktd`，同时创建 `reviews/history/`
3. 加载：
   - `reviews/config.rktd` — review 规则和平台配置
   - `reviews/preferences.rktd` — 用户偏好（severity 接受率、风格偏好），可能不存在
   - `reviews/history/` — 最近 3 条同仓库历史 review，用于保持一致性

注意：`reviews/` 是 per-project 运行时目录，不属于本 skill 仓库。

参考 `references/rktd-schemas.md` 了解完整 schema。

## 分析流程

对每个 changed file 执行：

1. **跳过判断**：检查 `preferences.rktd` 中 `ignore-paths`，跳过 vendor/generated 等目录
2. **规则匹配**：将 diff hunk 与 `config.rktd` 中 `(section . rule)` 记录匹配
3. **严重级别调整**：参考 `preferences.rktd` 中 `severity-stats`：
   - 若某 severity 的 `accept-rate` < 0.2，减少该级别评论数量
   - 若 `accept-rate` > 0.8，可适当增加
4. **评论生成**：为每个发现生成 inline-comment 记录
5. **数量控制**：总评论数不超过 `config.rktd` 中 `max-inline-comments`（默认 20）

### 评论质量要求

- 每条评论必须**具体**——引用代码行，说明问题和修复方案
- `critical` 和 `warning` 必须包含修复建议或代码示例
- `suggestion` 和 `nitpick` 可简要说明
- 避免纯风格偏好评论（除非 config 中明确配置了相关 rule）
- 评论语言：与 PR 内容的主要语言一致（中文项目用中文评论）

## 生成 comment.rktd

在项目根目录生成 `comment.rktd`，格式为 flat alist 多记录：

```racket
;; meta 记录
((section . meta)
 (pr-url . "https://github.com/owner/repo/pull/42")
 (platform . github)
 (owner . "owner") (repo . "repo") (pr-number . 42)
 (pr-title . "PR title here") (pr-author . "alice")
 (reviewed-at . "2026-03-19T10:30:00Z"))

;; 决策记录
((section . decision)
 (event . "REQUEST_CHANGES")   ; "APPROVE" | "REQUEST_CHANGES" | "COMMENT"
 (body . "Overall summary of the review..."))

;; inline 评论（每条一个记录）
((section . inline-comment)
 (id . 1) (path . "src/foo.rs") (line . 45) (side . "RIGHT")
 (body . "具体评论内容...")
 (severity . critical)
 (category . security)
 (rule-ref . "no-sql-injection"))
```

字段说明：
- `event`：根据发现的问题严重程度自动决定
  - 有 critical → `"REQUEST_CHANGES"`
  - 仅 warning/suggestion → `"COMMENT"`
  - 无问题 → `"APPROVE"`
- `line` + `side`：使用 diff 中的行号，`side` 为 `"RIGHT"`（新代码）或 `"LEFT"`（旧代码）
- `severity`：`critical` | `warning` | `suggestion` | `nitpick`
- `category`：`security` | `correctness` | `performance` | `style` | `docs`
- `rule-ref`：关联 config.rktd 中的规则 id，无关联则为 `#f`

使用 `writeln` 写入每条记录，确保每行一条。

## 生成 send-comment.rkt

直接将本 skill 目录下 `scripts/send-comment.rkt` 复制到项目根目录（或告知用户直接运行 `racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --file <path>`）。

脚本需包含：
- 硬编码的 `comment.rktd` 路径（项目根目录）
- 正确的平台 API 端点

生成后告知用户可用命令：
```bash
racket send-comment.rkt                    # 交互式发送
racket send-comment.rkt --dry-run          # 仅预览 API 调用
racket send-comment.rkt --non-interactive  # 直接全部发送
racket send-comment.rkt --skip-nitpicks    # 跳过 nitpick 级别
```

## 存档

将 `comment.rktd` 复制到 `reviews/history/<pr-number>-<timestamp>.rktd`。

## 输出摘要

完成后打印：

```
## PR Review 完成

**PR**: owner/repo#42 — "PR title"
**决策**: REQUEST_CHANGES
**评论统计**: 3 critical, 5 warning, 2 suggestion, 1 nitpick

### 文件
- `comment.rktd` — 评论数据（可编辑后再发送）
- `send-comment.rkt` — 发送脚本

### 使用方式
1. 查看/编辑 `comment.rktd`
2. 运行 `racket send-comment.rkt` 交互式发送
3. 或 `racket send-comment.rkt --dry-run` 预览
```

## 交互模式（--interactive）

当用户传入 `--interactive` 时，逐文件与用户讨论：

1. 显示文件 diff 摘要
2. 列出该文件的待评论列表
3. 用户可选择：保留 / 删除 / 修改每条评论
4. 全部文件处理完毕后再生成最终 comment.rktd

使用 AskUserQuestion 工具实现交互。

## 偏好学习

每次 review 完成后（send-comment.rkt 执行后），更新 `reviews/preferences.rktd`：

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

## 错误处理

- URL 格式无效 → 报错并给出正确格式示例
- `gh` 不可用且无 token → 提示安装 gh 或设置 GITHUB_TOKEN
- PR 不存在或无权限 → 显示 API 错误信息
- diff 过大（>100 files）→ 警告并只处理前 50 个文件

## 参考文件

- `references/rktd-schemas.md` — comment/config/preferences 完整 schema
- `references/api-reference.md` — GitHub/GitCode API 端点
- `examples/comment-example.rktd` — 输出示例
- `examples/config-example.rktd` — 配置示例
- `examples/preferences-example.rktd` — 偏好示例
- `scripts/send-comment.rkt` — 发送脚本模板
