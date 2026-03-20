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

支持分页：`?per_page=100&page=N`，或用 `gh api --paginate`。

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

### 认证（send-comment.rkt 查找优先级）
1. 环境变量 `GITHUB_TOKEN`
2. 项目目录 `./.github.token`
3. 用户主目录 `~/.github.token`
4. `gh auth token` 输出
- Header: `Authorization: token {token}`
- **Agent 禁止读取 token 文件**——Agent 仅通过 `gh api` 或 WebFetch 获取公开数据

### gh CLI 快捷方式
```bash
# PR 元数据
gh api repos/{owner}/{repo}/pulls/{n}

# PR diff
gh api repos/{owner}/{repo}/pulls/{n} -H "Accept: application/vnd.github.v3.diff"

# PR 文件列表（分页）
gh api repos/{owner}/{repo}/pulls/{n}/files --paginate

# 提交 PR review
gh api repos/{owner}/{repo}/pulls/{n}/reviews -X POST -f body="..." -f event="COMMENT"

# Commit 元数据 + files
gh api repos/{owner}/{repo}/commits/{sha}

# Commit diff
gh api repos/{owner}/{repo}/commits/{sha} -H "Accept: application/vnd.github.v3.diff"

# 提交 commit comment
gh api repos/{owner}/{repo}/commits/{sha}/comments -X POST -f body="..." -f path="file.rs" -F position=12
```

## GitCode

Base: `https://api.gitcode.com` (或自定义)

### PR 元数据
```
GET /repos/{owner}/{repo}/pulls/{pull_number}
```

### PR 文件列表
```
GET /repos/{owner}/{repo}/pulls/{pull_number}/files
```

### 提交 Review
```
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```

格式与 GitHub 兼容。认证查找优先级：
1. 环境变量 `GITCODE_TOKEN`
2. 项目目录 `./.gitcode.token`
3. 用户主目录 `~/.gitcode.token`
