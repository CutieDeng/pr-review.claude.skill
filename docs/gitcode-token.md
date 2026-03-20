# 获取 GitCode 访问令牌

本文介绍如何在 GitCode 平台创建个人访问令牌（Access Token），供 `send-comment.rkt` 发送评论时使用。

## 步骤

### 1. 进入安全设置

登录 GitCode 后，点击右上角头像 → **设置** → 左侧菜单 **安全设置** → **访问令牌**。

直达链接：`https://gitcode.com/-/profile/tokens`

### 2. 创建新令牌

点击 **创建访问令牌**，填写：

- **令牌名称**：自定义，如 `pr-review`
- **过期时间**：按需设置，建议不超过 90 天
- **权限范围**：勾选以下权限
  - `api` — 完整 API 访问（发送评论必需）
  - `read_repository` — 读取仓库内容（获取 diff 必需）

点击 **创建** 后，页面会显示生成的令牌字符串。

**注意**：令牌只在创建时显示一次，务必立即复制保存。

### 3. 配置令牌

创建后将令牌配置到以下任一位置（按优先级排列）：

#### 方式 A：环境变量（推荐）

```bash
# 写入 shell 配置文件
echo 'export GITCODE_TOKEN="your-token-here"' >> ~/.bashrc
source ~/.bashrc
```

fish shell：

```fish
set -Ux GITCODE_TOKEN "your-token-here"
```

#### 方式 B：项目级 token 文件

在项目根目录创建 `.gitcode.token` 文件：

```bash
echo "your-token-here" > .gitcode.token
```

确保该文件已加入 `.gitignore`：

```bash
echo ".gitcode.token" >> .gitignore
```

#### 方式 C：用户级 token 文件

```bash
echo "your-token-here" > ~/.gitcode.token
chmod 600 ~/.gitcode.token
```

### 4. 验证

```bash
# 用 send-comment.rkt 的 dry-run 模式验证认证是否生效
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --dry-run --file comment.rktd
```

如果没有报认证错误，说明配置成功。

## 令牌安全

- 不要将令牌提交到 git 仓库
- `.gitcode.token` 文件应加入 `.gitignore`
- 定期轮换令牌
- 如果令牌泄露，立即在 GitCode 安全设置中撤销
