# pr-review

Claude Code skill for automated PR review. Generates structured `comment.rktd` and an interactive `send-comment.rkt` script.

## Install

```bash
git clone <repo-url> ~/.claude/skills/pr-review
```

## Usage

In Claude Code:

```
/pr-review https://github.com/owner/repo/pull/42
```

This will:
1. Fetch PR/commit diff via `fetch-diff.rkt` (GitHub & GitCode API)
2. Analyze changes against configured rules
3. Generate `comment.rktd` (structured review data)
4. Provide `send-comment.rkt` for submitting comments

### Send comments

```bash
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --file comment.rktd           # interactive
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --file comment.rktd --dry-run  # preview only
```

## Auth

`send-comment.rkt` looks for tokens in this order:

1. Env var (`GITHUB_TOKEN` / `GITCODE_TOKEN`)
2. Project-local `.github.token` / `.gitcode.token`
3. `~/.github.token` / `~/.gitcode.token`
4. `gh auth token` (GitHub only)

## Structure

```
SKILL.md                                # Skill definition
scripts/
  fetch-diff.rkt                        # Fetch PR/commit diff from GitHub/GitCode API
  send-comment.rkt                      # Interactive comment sender
docs/
  gitcode-token.md                      # GitCode token setup guide
references/
  api-reference.md                      # GitHub/GitCode API reference
  rktd-schemas.md                       # comment.rktd schema docs
examples/
  comment-example.rktd                  # PR inline comment example
  commit-comment-example.rktd           # Commit comment example
  config-example.rktd                   # Config file example
  preferences-example.rktd              # Preferences file example
```

Per-project `.skill.pr-review.history/` directory is created on first run (not part of this repo).
