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
1. Fetch PR diff via `gh api` or WebFetch
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
SKILL.md                  # Skill definition
scripts/send-comment.rkt  # Interactive comment sender
references/               # Schema docs, API reference
examples/                 # Sample .rktd files
```

Per-project `reviews/` directory is created on first run (not part of this repo).
