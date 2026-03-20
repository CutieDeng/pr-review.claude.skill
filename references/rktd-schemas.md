# .rktd Schema 参考

所有 `.rktd` 文件使用 flat alist 多记录格式。每行一条 `writeln` 输出的 S-expression。
用 `section` 字段区分记录类型。

## comment.rktd

### meta 记录（恰好 1 条）

**通用字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `meta` | 记录类型标识 |
| `review-type` | symbol | `pr` \| `commit` |
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

## config.rktd

### platform 记录

| 字段 | 类型 | 说明 |
|------|------|------|
| `section` | symbol `platform` | |
| `name` | symbol | `github` \| `gitcode` |
| `api-base` | string | API 根 URL |
| `auth-env` | string | 认证环境变量名 |
| `auth-fallback` | string | 备用认证命令 |

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
