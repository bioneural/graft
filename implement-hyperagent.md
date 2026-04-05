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

Create every file listed in the §1 repo structure tree, with the exact contents specified in the corresponding sections. The section reference is noted next to each file in the tree (e.g. `§5`, `§6`). Mark files executable where the spec says to — look for `chmod +x` directives at the end of each section. For empty directories (like `tools/`), add a `.gitkeep` file so git tracks them.

After creating all files, stamp the graft version used to generate the hyperagent:

```bash
gh api repos/bioneural/graft/commits --jq '.[0].sha' > .graft-version
```

This records which graft commit the hyperagent was generated from. The `/hyperagent-upgrade` skill uses it as the baseline for diffing upstream changes.

Do NOT create any of the files listed in the §2 `.gitignore`. These are ephemeral runtime files created by `install.sh` or at runtime.

## Step 3: Create the README

Create `README.md` with the content below. Replace `GH_USER` with the actual GitHub username and `INSTALL_DIR` with the actual install directory path provided in your prompt.

````markdown
# Hyperagent

A self-improving system for Claude Code. It observes your sessions, identifies patterns in what goes well and what doesn't, and modifies Claude Code's configuration to improve over time. It can also modify its own observation and improvement strategies.

**You own your hyperagent.** It was generated from the [Graft](https://github.com/bioneural/graft) blueprint, but it's yours now — an independent repo you can modify, extend, or rewrite however you want. Use `/hyperagent-upgrade` to pull blueprint updates into your hyperagent and contribute your best local improvements back to Graft.

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

- `/hyperagent-reload` — review and apply hyperagent configuration changes without restarting
- `/hyperagent-changelog` — show recent hyperagent changes
- `/hyperagent-revert` — roll back a specific hyperagent change
- `/hyperagent-status` — check watcher health and recent activity
- `/hyperagent-issue` — file an issue on the Graft repo with diagnostics
- `/hyperagent-upgrade` — check for Graft blueprint updates and contribute local improvements back

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

All validation derives from the spec. Do not hardcode lists — cross-reference the spec sections so that adding something to the spec automatically extends the checks.

Run these checks before committing:

1. **All required files exist.** Parse the repo structure tree in §1. For every file path listed, verify it exists under INSTALL_DIR. Also verify `README.md`, `tools/.gitkeep`, and `.graft-version`.

2. **Scripts are executable.** Find every `chmod +x` directive in the spec. Verify each named file has its executable bit set.

3. **`.gitignore` is complete.** Parse the code block in §2. For every non-comment, non-blank line, verify it appears in `.gitignore`.

4. **All skills reference the config file.** For every skill defined in §3, verify its `SKILL.md` contains `hyperagent.json`.

5. **`.graft-version` is valid.** Verify it contains a 40-character hex SHA.

6. **No python references.** `grep -r "python3\|python" --include="*.sh" --include="*.md" .` should find nothing.

7. **Watcher uses jq.** `grep -q "jq" watcher.sh`.

8. **`install.sh` checks all dependencies.** The spec intro lists all dependencies. For each one, verify `install.sh` contains a `command -v` check for it.

9. **`install.sh` sets up a system service.** Verify it references `launchctl` or `systemctl`.

10. **`uninstall.sh` tears down the system service.** Verify it references `launchctl` or `systemctl`.

11. **README has no placeholders.** Verify `README.md` does not contain the literal strings `GH_USER` or `INSTALL_DIR`.

12. **Shell scripts pass `shellcheck`.** If `shellcheck` is available, run it on all `.sh` files and fix any errors.

If all checks pass, print `ALL CHECKS PASSED`.

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
