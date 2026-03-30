# Implement Hyperagent

You are implementing a self-improving system for Claude Code. Read the spec at `hyperagent-spec.md` in full before writing any code. The spec is the source of truth. These instructions tell you the order of operations and the deployment steps.

The GitHub username is provided in your prompt. If not, detect it:

```bash
GH_USER=$(gh api user --jq '.login')
```

## Prerequisites

Verify before starting:

```bash
command -v git || { echo "FAIL: git not found"; exit 1; }
command -v gh || { echo "FAIL: gh not found"; exit 1; }
command -v jq || { echo "FAIL: jq not found"; exit 1; }
command -v claude || { echo "FAIL: claude not found"; exit 1; }
gh auth status || { echo "FAIL: not authenticated with gh"; exit 1; }
```

## Step 1: Create the repo

```bash
mkdir -p INSTALL_DIR
cd INSTALL_DIR
git init .
git config user.name "Hyperagent"
git config user.email "hyperagent@local"
```

## Step 2: Create all files from the spec

Create every file listed in §1 of the spec, with the exact contents specified in the corresponding sections. The files are:

1. `.gitignore` — §2
2. `meta_agent.md` — §5 (the full markdown content inside the code fence)
3. `watcher.sh` — §6 (the full bash script). Mark executable.
4. `memory.md` — §7
5. `changelog.md` — §8
6. `tools/` — empty directory. Add a `.gitkeep` file so git tracks it.
7. `hooks/on-session-start.sh` — §9. Mark executable.
8. `hooks/on-prompt.sh` — §9. Mark executable.
9. `skills/hyperagent-reload/SKILL.md` — §3
10. `skills/hyperagent-changelog/SKILL.md` — §3. Leave `HYPERAGENT_DIR_PLACEHOLDER` as-is. `install.sh` patches it.
11. `skills/hyperagent-revert/SKILL.md` — §3. Leave `HYPERAGENT_DIR_PLACEHOLDER` as-is.
12. `skills/hyperagent-status/SKILL.md` — §3. Leave `HYPERAGENT_DIR_PLACEHOLDER` as-is.
13. `install.sh` — §10. Mark executable.
14. `uninstall.sh` — §11. Mark executable.

Do NOT create runtime files (`ledger`, `.last-check`, `.lock`, `.last-change`, `.heartbeat`, `.seen/`). These are created by `install.sh` or at runtime.

## Step 3: Create the README

Create `README.md` with the content below. Replace `GH_USER` with the actual GitHub username and `INSTALL_DIR` with the actual install directory path provided in your prompt.

````markdown
# Hyperagent

A self-improving system for Claude Code. It observes your sessions, identifies patterns in what goes well and what doesn't, and modifies Claude Code's configuration to improve over time. It can also modify its own observation and improvement strategies.

## Install

```bash
gh repo clone GH_USER/hyperagent INSTALL_DIR
INSTALL_DIR/install.sh
```

Restart Claude Code to pick up the hooks. The watcher runs as a system service — it starts automatically and survives reboots.

## What it does

- Watches your Claude Code session transcripts for patterns
- When a session goes idle for 5 minutes, analyzes what happened
- If it finds something worth improving, modifies your Claude Code configuration
- Notifies you at session start or on your next message
- Tracks every change in a changelog with full diffs for rollback

## What it modifies

- `~/.claude/CLAUDE.md` — universal preferences (across all projects)
- `<project>/CLAUDE.md` — project-specific conventions
- `<project>/.claude/rules/` — scoped rules (path-targeted or global)
- `<project>/<subdir>/CLAUDE.md` — subdirectory-specific instructions
- Skills, agents, commands at any level
- Its own meta agent definition (`meta_agent.md`)

## Skills

- `/hyperagent-reload` — restart Claude Code to pick up CLAUDE.md changes
- `/hyperagent-changelog` — show recent hyperagent changes
- `/hyperagent-revert` — roll back a specific hyperagent change
- `/hyperagent-status` — check watcher health and recent activity

## Rollback

Say "roll back the last hyperagent change" in any Claude Code session, or run `/hyperagent-revert`.

## Uninstall

```bash
INSTALL_DIR/uninstall.sh
```

## Dependencies

- bash
- Claude Code CLI (`claude`)
- gh
- git
- jq
````

## Step 4: Validate

Run these checks before committing:

```bash
cd INSTALL_DIR

# All required files exist
for f in .gitignore meta_agent.md watcher.sh memory.md changelog.md \
         hooks/on-session-start.sh hooks/on-prompt.sh \
         skills/hyperagent-reload/SKILL.md skills/hyperagent-changelog/SKILL.md skills/hyperagent-revert/SKILL.md skills/hyperagent-status/SKILL.md \
         install.sh uninstall.sh README.md tools/.gitkeep; do
    [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

# Scripts are executable
for f in watcher.sh hooks/on-session-start.sh hooks/on-prompt.sh install.sh uninstall.sh; do
    [ -x "$f" ] || { echo "NOT EXECUTABLE: $f"; exit 1; }
done

# .gitignore contains required entries
for entry in ledger .last-check .lock .last-change .heartbeat .seen/; do
    grep -qF "$entry" .gitignore || { echo "MISSING FROM .gitignore: $entry"; exit 1; }
done

# Skills contain placeholder (not yet patched)
for f in skills/hyperagent-changelog/SKILL.md skills/hyperagent-revert/SKILL.md skills/hyperagent-status/SKILL.md; do
    grep -q "HYPERAGENT_DIR_PLACEHOLDER" "$f" || { echo "MISSING PLACEHOLDER: $f"; exit 1; }
done

# No python references
grep -r "python3\|python" --include="*.sh" --include="*.md" . && { echo "FAIL: python reference found"; exit 1; } || true

# Watcher uses jq for project path resolution
grep -q "jq" watcher.sh || { echo "FAIL: watcher.sh should use jq"; exit 1; }

# install.sh checks all prerequisites
for dep in claude git jq; do
    grep -q "command -v $dep" install.sh || { echo "FAIL: install.sh missing check for $dep"; exit 1; }
done

# install.sh sets up system service
grep -q "launchctl\|systemctl" install.sh || { echo "FAIL: install.sh missing service setup"; exit 1; }

# uninstall.sh tears down system service
grep -q "launchctl\|systemctl" uninstall.sh || { echo "FAIL: uninstall.sh missing service teardown"; exit 1; }

# README has actual username and path, not placeholders
grep -q 'GH_USER' README.md && { echo "FAIL: README still has GH_USER placeholder"; exit 1; } || true
grep -q 'INSTALL_DIR' README.md && { echo "FAIL: README still has INSTALL_DIR placeholder"; exit 1; } || true

echo "ALL CHECKS PASSED"
```

## Step 5: Commit

```bash
cd INSTALL_DIR
git add -A
git commit --author="Hyperagent <hyperagent@local>" -m "[hyperagent] initial implementation"
```

## Step 6: Create the GitHub repo and push

```bash
cd INSTALL_DIR
gh repo create "$GH_USER/hyperagent" --private --source=. --push \
    --description "A self-improving system for Claude Code"
```

## Step 7: Verify

```bash
gh repo view "$GH_USER/hyperagent"
```

Confirm:
- The repo exists and is private
- The description is set
- All files are present on the remote

## Done

The repo is at `github.com/$GH_USER/hyperagent`. To install on any machine:

```bash
gh repo clone $GH_USER/hyperagent INSTALL_DIR
INSTALL_DIR/install.sh
```
