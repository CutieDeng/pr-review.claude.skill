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

### 认证（send-comment.rkt 查找优先级）
1. 环境变量 `GITHUB_TOKEN`
2. 项目目录 `./.github.token`
3. 用户主目录 `~/.github.token`
4. `gh auth token` 输出
- Header: `Authorization: token {token}`
- **Agent 禁止读取 token 文件**——Agent 仅通过 `gh api` 或 WebFetch 获取公开数据

### gh CLI 快捷方式
```bash
# 等价于 GET /repos/{owner}/{repo}/pulls/{n}
gh api repos/{owner}/{repo}/pulls/{n}

# 获取 diff
gh api repos/{owner}/{repo}/pulls/{n} -H "Accept: application/vnd.github.v3.diff"

# 分页获取文件
gh api repos/{owner}/{repo}/pulls/{n}/files --paginate

# 提交 review
gh api repos/{owner}/{repo}/pulls/{n}/reviews -X POST -f body="..." -f event="COMMENT"
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
