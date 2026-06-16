# .rktd Schema 参考

所有 `.rktd` 文件使用 flat alist 多记录格式。每行一条 `writeln` 输出的 S-expression。
用 `section` 字段区分记录类型。

## comment.rktd

### meta 记录（恰好 1 条）

**通用字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `meta` | 记录类型标识 |
| `review-type` | symbol | `pr` \| `commit` \| `issue` \| `pr-create` |
| `platform` | symbol | `github` \| `gitcode` |
| `owner` | string | 仓库所有者 |
| `repo` | string | 仓库名 |
| `reviewed-at` | string | ISO 8601 时间戳 |

**PR 专有字段**（`review-type` = `pr`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `pr-url` | string | PR 完整 URL |
| `pr-number` | integer | PR 编号 |
| `pr-title` | string | PR 标题 |
| `pr-author` | string | PR 作者 |

**Commit 专有字段**（`review-type` = `commit`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `commit-url` | string | Commit 完整 URL |
| `commit-sha` | string | 完整 commit SHA |
| `commit-message` | string | commit 消息（首行） |
| `commit-author` | string | commit 作者 |

**pr-create 专有字段**（`review-type` = `pr-create`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `compare-url` | string 或 `#f` | compare URL（若 URL 为 compare 形式） |
| `target-owner` | string | 目标仓库 owner（与 `owner` 同义，pr-create 推荐） |
| `target-repo` | string | 目标仓库 name（与 `repo` 同义，pr-create 推荐） |

### decision 记录

- **PR**：恰好 1 条，必须包含 `event`
- **Commit**：可选（0 或 1 条），仅含 `body`，作为总结评论发送

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `decision` | 记录类型标识 |
| `event` | string（仅 PR） | `"APPROVE"` \| `"REQUEST_CHANGES"` \| `"COMMENT"` |
| `body` | string | 总体评审摘要 |

### inline-comment 记录（0 到 N 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `inline-comment` | 记录类型标识 |
| `id` | integer | 从 1 开始的序号 |
| `path` | string | 文件相对路径 |
| `line` | integer | PR：文件行号；Commit：diff 中的 position |
| `side` | string | `"RIGHT"`（新代码）\| `"LEFT"`（旧代码）。Commit 模式可省略 |
| `body` | string | 评论内容 |
| `severity` | symbol | `critical` \| `warning` \| `suggestion` \| `nitpick` |
| `category` | symbol | `security` \| `correctness` \| `performance` \| `style` \| `docs` |
| `rule-ref` | string 或 `#f` | 关联 config.rktd 规则 id |

### reply 记录（0 到 N 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `reply` | 记录类型标识 |
| `id` | integer | 从 1 开始的序号 |
| `in-reply-to` | integer | 目标评论的 API comment ID |
| `comment-type` | symbol | `review-comment`（PR inline）\| `issue-comment`（PR 会话）\| `commit-comment` |
| `discussion-id` | string 或 `#f` | GitCode 专用：讨论 ID（从 PR 评论的 `discussion_id` 字段获取）。GitCode 回复必需，GitHub 忽略 |
| `body` | string | 回复内容 |
| `context` | string 或 `#f` | 引用的原评论摘要（仅供阅读，不发送） |

### issue 记录（0 到 N 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `issue` | 记录类型标识 |
| `id` | integer | 从 1 开始的序号 |
| `title` | string | Issue 标题（必填） |
| `body` | string | Issue 正文，支持 Markdown（必填） |
| `labels` | list of strings | 标签列表（可选，默认空） |
| `assignees` | list of strings | 指派人列表（可选，默认空） |
| `milestone` | integer 或 `#f` | 里程碑编号（可选） |
| `source-context` | string 或 `#f` | 来源上下文（仅供阅读，不发送） |

### issue-update 记录（0 到 N 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `issue-update` | 记录类型标识 |
| `id` | integer | 从 1 开始的序号 |
| `issue-number` | integer | 目标 Issue 编号（必填） |
| `state` | symbol | `open` \| `closed`（可选） |
| `state-reason` | symbol | `completed` \| `not_planned` \| `reopened`（可选，仅 GitHub） |
| `title` | string 或 `#f` | 新标题（可选） |
| `body` | string 或 `#f` | 新正文（可选） |
| `labels` | list of strings 或 `#f` | 新标签列表（可选，覆盖式） |
| `assignees` | list of strings 或 `#f` | 新指派人列表（可选，覆盖式） |

### pr-create 记录（最多 1 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `pr-create` | 记录类型标识 |
| `id` | integer | 固定为 1（schema 限制最多 1 条） |
| `title` | string | PR 标题（必填） |
| `body` | string | PR 正文，支持 Markdown（可选，默认 `""`） |
| `head` | string | 源分支；跨 fork 时格式 `<source-owner>:<branch>`（必填） |
| `base` | string | 目标基准分支（必填） |
| `draft` | boolean | 是否为 draft PR（可选，默认 `#f`） |
| `maintainer-can-modify` | boolean | 跨 fork 时允许 maintainer 修改源分支（可选，默认 `#t`） |

### pr-update 记录（0 到 N 条）

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `pr-update` | 记录类型标识 |
| `id` | integer | 从 1 开始的序号 |
| `pr-number` | integer | 目标 PR 编号（必填） |
| `state` | symbol 或 `#f` | `open` \| `closed`（可选） |
| `title` | string 或 `#f` | 新标题（可选） |
| `body` | string 或 `#f` | 新正文（可选） |
| `base` | string 或 `#f` | 新目标分支（可选） |
| `draft` | boolean 或 symbol `ready` 或 `#f` | `#t`=转 draft；`'ready`=取消 draft（GraphQL）；`#f`=不修改 |

## config.rktd

### platform 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `platform` | |
| `name` | symbol | `github` \| `gitcode` |
| `api-base` | string | API 根 URL |
| `auth-env` | string | 认证环境变量名 |
| `auth-fallback` | string 或 `#f` | 备用认证命令；默认可为 `#f`，不要把 `gh` 作为必需依赖 |

### rule 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `rule` | |
| `id` | string | 规则唯一标识 |
| `description` | string | 规则描述 |
| `severity` | symbol | 默认严重级别 |
| `category` | symbol | 所属类别 |

### settings 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `settings` | |
| `default-mode` | symbol | `auto` \| `interactive` |
| `max-inline-comments` | integer | 最大评论数（默认 20） |
| `action-mode` | symbol | `interactive` \| `direct-send` \| `dry-run`。默认 `interactive`；仅在用户明确要求或配置允许时执行写操作 |

## preferences.rktd

### severity-stats 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `severity-stats` | |
| `severity` | symbol | 严重级别 |
| `total` | integer | 总评论数 |
| `accepted` | integer | 用户接受数 |
| `accept-rate` | float | 接受率 |

### style-preference 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `style-preference` | |
| `note` | string | 风格偏好描述 |

### repo-preference 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `repo-preference` | |
| `repo` | string | `"owner/repo"` 格式 |
| `focus-areas` | list of symbols | 重点关注类别 |
| `ignore-paths` | list of strings | 忽略路径 glob |
