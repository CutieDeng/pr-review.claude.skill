# API 端点参考

## GitHub

Base: `https://api.github.com`

### PR 元数据
```
GET /repos/{owner}/{repo}/pulls/{pull_number}
```
返回：title, user.login, state, body, head, base 等。

### PR Diff
```
GET /repos/{owner}/{repo}/pulls/{pull_number}
Accept: application/vnd.github.v3.diff
```
返回原始 unified diff 文本。

### PR 文件列表
```
GET /repos/{owner}/{repo}/pulls/{pull_number}/files
```
返回 JSON array，每个元素含：
- `filename` — 文件路径
- `status` — added/removed/modified/renamed
- `additions` / `deletions` — 行数统计
- `patch` — unified diff（可能被截断）

支持分页：`?per_page=100&page=N`。

### 创建 PR
```
POST /repos/{owner}/{repo}/pulls
```
Body:
```json
{
  "title": "Add foo support",
  "body": "Description...",
  "head": "alice:feature-foo",
  "base": "main",
  "draft": false,
  "maintainer_can_modify": true
}
```

**注意**：
- `head` 跨 fork 时使用 `<source-owner>:<branch>` 格式；同仓库 PR 直接填分支名
- `{owner}/{repo}` 是 **目标仓库**（PR 合并到的仓库）
- 返回 201 Created，响应含 `html_url`、`number`

### 更新/关闭 PR
```
PATCH /repos/{owner}/{repo}/pulls/{pull_number}
```
Body（任选字段）：
```json
{
  "title": "...",
  "body": "...",
  "state": "closed",
  "base": "develop"
}
```

**注意**：
- `state` 只支持 `"open"` / `"closed"`
- 取消 draft 状态（`ready_for_review`）需用 GraphQL `markPullRequestReadyForReview`，REST API 不支持
- 转为 draft 同样需 GraphQL `convertPullRequestToDraft`

### 比较两个 ref（compare）
```
GET /repos/{owner}/{repo}/compare/{base}...{head}
```
返回 JSON 含 `commits`、`files`、`status`、`ahead_by`、`behind_by`。`head` 跨 fork 时格式同上。
用于 `--mode pr-create` 预览将要创建的 PR 内容。

### 提交 Review
```
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```
Body:
```json
{
  "body": "Overall comment",
  "event": "APPROVE" | "REQUEST_CHANGES" | "COMMENT",
  "comments": [
    {
      "path": "file.rs",
      "line": 45,
      "side": "RIGHT",
      "body": "Inline comment"
    }
  ]
}
```

**注意**：
- `line` 是 diff 上下文中的行号（不是 position）
- `side`: `RIGHT` = 新代码, `LEFT` = 旧代码
- 若使用 `line`，需同时提供 `side`
- `event` 为 `APPROVE` 或 `REQUEST_CHANGES` 时必须有 PR 的 review 权限

### 获取 PR 评论

```
# PR review comments（inline 代码评论）
GET /repos/{owner}/{repo}/pulls/{pull_number}/comments

# PR issue comments（会话级评论）
GET /repos/{owner}/{repo}/issues/{pull_number}/comments
```

Review comment 返回字段：`id`, `user.login`, `body`, `path`, `line`, `side`, `in_reply_to_id`, `created_at`
Issue comment 返回字段：`id`, `user.login`, `body`, `created_at`

### 回复 PR 评论

```
# 回复 inline review comment — 使用 in_reply_to 字段
POST /repos/{owner}/{repo}/pulls/{pull_number}/comments
```
Body:
```json
{
  "body": "Reply text",
  "in_reply_to": 12345
}
```

```
# 回复 issue comment（会话级）— 直接发 issue comment
POST /repos/{owner}/{repo}/issues/{pull_number}/comments
```
Body:
```json
{
  "body": "Reply text"
}
```

### Commit 元数据
```
GET /repos/{owner}/{repo}/commits/{sha}
```
返回 JSON 含 `sha`, `commit.message`, `commit.author`, `files[]` 等。

### Commit Diff
```
GET /repos/{owner}/{repo}/commits/{sha}
Accept: application/vnd.github.v3.diff
```
返回原始 unified diff 文本。

### 提交 Commit Comment（逐条）
```
POST /repos/{owner}/{repo}/commits/{sha}/comments
```
Body:
```json
{
  "body": "Comment text",
  "path": "file.rs",
  "position": 12
}
```

**注意**：
- `position` 是 diff 中的行位置（从 1 开始），不是文件行号
- `path` 和 `position` 可选；省略则为 commit 级别的通用评论
- 每条评论单独发送，无批量 API
- 返回 201 Created

### 获取 Commit 评论
```
GET /repos/{owner}/{repo}/commits/{sha}/comments
```
返回字段：`id`, `user.login`, `body`, `path`, `position`, `created_at`

### 认证（脚本内部查找优先级）
1. 环境变量 `GITHUB_TOKEN`
2. 项目目录 `./.github.token`
3. 用户主目录 `~/.github.token`
4. 可选 fallback：`gh auth token` 输出（不可用属正常情况，不作为 agent 前置条件）
- Header: `Authorization: token {token}`
- **Agent 禁止读取 token 文件**。Agent 默认通过 `fetch-diff.rkt` 或 `WebFetch` 获取数据，不检查 `gh` 状态。

## GitCode

Base: `https://api.gitcode.com/api/v5`

认证：`Authorization: Bearer {token}` header（与 gitcode_mcp_server 对齐）。

认证查找优先级：
1. 环境变量 `GITCODE_TOKEN`
2. 项目目录 `./.gitcode.token`
3. 用户主目录 `~/.gitcode.token`

### PR 元数据
```
GET /repos/{owner}/{repo}/pulls/{pull_number}
```

### PR 文件列表
```
GET /repos/{owner}/{repo}/pulls/{pull_number}/files
```

### 创建 PR
```
POST /repos/{owner}/{repo}/pulls
```
Parameters（formData）：
- `title`*（string）— 必填
- `head`*（string）— 必填，源分支（GitCode 跨仓库需用 `owner:branch`，同仓库直接分支名）
- `base`*（string）— 必填，目标基准分支
- `body`（string）— 可选
- `draft`（boolean）— 可选

返回 201 Created。

### 更新/关闭 PR
```
PATCH /repos/{owner}/{repo}/pulls/{pull_number}
```
Parameters（formData）：`title` / `body` / `state`（`open` | `closed`） / `base`，按需提供。

### 获取 PR 评论
```
GET /repos/{owner}/{repo}/pulls/{pull_number}/comments
```
返回字段包含 `comment_type`：
- `"diff_comment"` — 代码行评论（inline）
- `"pr_comment"` — 普通 PR 评论

每条评论含 `discussion_id` 字段，用于回复。

### 创建 PR 评论
```
POST /repos/{owner}/{repo}/pulls/{pull_number}/comments
```
Parameters（formData）：
- `body`*（string）— 必填，评论内容
- `commit_id`（string）— 可选，PR 代码评论的 commit id
- `path`（string）— 可选，PR 代码评论的文件名
- `position`（integer）— 可选，PR 代码评论 diff 中的行数

省略 `path`/`position` 则为普通 PR 评论，带上则为 inline 代码评论。

参考：https://gitee.com/api/v5/swagger#/postV5ReposOwnerRepoPullsNumberComments

### 回复 PR 评论
```
POST /repos/{owner}/{repo}/pulls/{pull_number}/discussions/{discussion_id}/comments
```
Body:
```json
{
  "body": "Reply text"
}
```
`discussion_id` 从评论的 `discussion_id` 字段获取。**注意**：GitCode 不使用 GitHub 的 `in_reply_to` 机制。

### 获取单条 PR 评论详情
```
GET /repos/{owner}/{repo}/pulls/comments/{comment_id}
```
返回完整评论信息，包含 `discussion_id`。

### 提交 Review
```
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```
**不可用**——即使使用 `api.gitcode.com` 仍返回 404。

**替代方案**：decision 作为普通评论（`POST .../comments`，不带 `path`/`position`），inline comments 逐条带 `path`+`position` 发送。

### Commit 评论
```
GET /repos/{owner}/{repo}/commits/{sha}/comments
POST /repos/{owner}/{repo}/commits/{sha}/comments
```
Body:
```json
{
  "body": "Comment text"
}
```
**限制**：GitCode commit comment API **不支持** inline 定位（`path`/`position` 被忽略）。所有评论均为 commit 级别通用评论。需要 inline 效果时，在 body 中嵌入 `**\`path:line\`**` 前缀。
