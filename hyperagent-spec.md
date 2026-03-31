# Hyperagent Implementation Spec

A standalone self-improving service for Claude Code. It lives in its own repo, runs as its own process, observes session transcripts, and modifies Claude Code configuration to improve over time. It can modify its own definition and build its own tools.

Two deliverables: a bash watcher and a meta agent definition, plus supporting skills and hooks.

Dependencies: bash, Claude Code CLI (`claude`), `gh`, `git`, `jq`.

---

## 1. Repo Structure

Clone this repo anywhere (e.g. `~/hyperagent`). It is its own git repository with its own remote. All paths below are relative to the repo root unless prefixed with `~/` or `<project>`.

```
hyperagent/
├── meta_agent.md              # Meta agent definition. Self-modifiable. §5.
├── watcher.sh                 # Bash daemon. Fixed. §6.
├── memory.md                  # Accumulated insights. §7.
├── changelog.md               # Full record of all changes with diffs. §8.
├── tools/                     # Scripts the meta agent builds for itself. §12.
├── hooks/
│   ├── on-session-start.sh    # SessionStart hook. Fixed. §9.
│   └── on-prompt.sh           # UserPromptSubmit hook. Fixed. §9.
├── skills/
│   ├── hyperagent-reload/SKILL.md  # /hyperagent-reload skill. §3.
│   ├── hyperagent-changelog/SKILL.md # /hyperagent-changelog skill. §3.
│   ├── hyperagent-revert/SKILL.md  # /hyperagent-revert skill. §3.
│   ├── hyperagent-status/SKILL.md  # /hyperagent-status skill. §3.
│   ├── hyperagent-issue/SKILL.md  # /hyperagent-issue skill. §3.
│   └── hyperagent-upgrade/SKILL.md # /hyperagent-upgrade skill. §3.
├── .graft-version             # Graft commit SHA this hyperagent was generated from.
├── install.sh                 # Sets up integration points. §10.
├── uninstall.sh               # Removes integration points. §11.
├── .gitignore                 # §2.
└── README.md
```

---

## 2. `.gitignore`

```
ledger
.last-check
.lock
.last-change
.heartbeat
.seen/
.last-upgrade-check
.upgrade-available
discussions/
```

Everything else is tracked, including `tools/`, `meta_agent.md`, `memory.md`, `changelog.md`, `hooks/`, and `skills/`.

---

## 3. Skills

Skills are the modern Claude Code extensibility system. They live in `.claude/skills/<n>/SKILL.md`, support YAML frontmatter, hot-reload mid-session (no restart required for new or modified skills), and can be auto-invoked or manually invoked via `/name`.

The hyperagent ships six skills. `install.sh` symlinks them into `~/.claude/skills/` so they're available globally. All skill names are prefixed with `hyperagent-` to avoid collisions with other tools.

Skills that reference the hyperagent repo directory do so by reading `~/.claude/hyperagent.json`, which `install.sh` creates. This file contains `{"hyperagent_dir": "<resolved path>"}`. Skills remain portable in source — no patching required.

### `skills/hyperagent-reload/SKILL.md`

```markdown
---
name: hyperagent-reload
description: Check for and apply hyperagent configuration changes. Use when the hyperagent notifies you of updates.
---
# Apply Hyperagent Changes

First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

1. Read the hyperagent changelog at `<hyperagent_dir>/changelog.md`. Identify entries newer than the last reload (or all entries if this is the first run).
2. For each change, classify it:
   - **Hooks or permissions in `settings.json`** — already live via file watcher. Report as applied.
   - **Skills or agents** — already live via hot-reload. Report as applied.
   - **CLAUDE.md or rules files** — report what changed. These will take effect on the next `/compact` or session start.
   - **MCP server configurations** — report that a session restart is required. Do not terminate the session.
3. Summarize: list each change, its category, and its reload status.
4. If CLAUDE.md or rules were modified, tell the user: "These changes will take effect on the next /compact or session start."
5. If MCP servers were modified, tell the user: "MCP changes require a session restart. Run claude --resume when ready."
```

### `skills/hyperagent-changelog/SKILL.md`

```markdown
---
name: hyperagent-changelog
description: Show recent hyperagent changes. Use when user asks about what the hyperagent has changed, or after receiving a hyperagent notification.
disable-model-invocation: true
---
First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

Read the hyperagent changelog file and display the 10 most recent entries. Each entry starts with a `## ` heading containing a timestamp.

Changelog location: `<hyperagent_dir>/changelog.md`

If the user provides arguments: $ARGUMENTS — use them to filter (e.g. "this week", "last 5", "show all", a specific date).
```

### `skills/hyperagent-revert/SKILL.md`

```markdown
---
name: hyperagent-revert
description: Roll back a hyperagent change. Use when user says "undo", "roll back", or "revert" in reference to a hyperagent change, or when user is unhappy with a recent Claude Code behavior change.
disable-model-invocation: true
---
# Revert a Hyperagent Change

First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

1. Read the hyperagent changelog at `<hyperagent_dir>/changelog.md`.
2. Show the user the 5 most recent entries with their timestamps and TL;DR lines.
3. Ask the user which entry to revert (or confirm if they said "the last one").
4. Read the **Diff** block from that changelog entry. The `< ` lines are the previous content. The `> ` lines are the current content.
5. Determine the target file from the **Target** field.
6. For files under `~/.claude/`:
   - Read the current file content.
   - Replace the `> ` content with the `< ` content from the diff.
   - Write the file back.
7. For files under a project directory:
   - Run `git log --author="Hyperagent" --oneline` in the project repo to find the corresponding commit.
   - Run `git revert <hash> --no-edit` in the project repo.
8. Append a revert entry to `<hyperagent_dir>/changelog.md` documenting what was reverted and why.
9. Tell the user to `/hyperagent-reload` to review what changed.
```

### `skills/hyperagent-status/SKILL.md`

```markdown
---
name: hyperagent-status
description: Check whether the hyperagent watcher is running and show recent activity. Use when user asks about hyperagent health or status.
disable-model-invocation: true
---
# Hyperagent Status

First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

Check the following and report to the user:

1. **Watcher process**: Check if the watcher is running.
   - macOS: `launchctl list com.bioneural.hyperagent 2>/dev/null`
   - Linux: `systemctl --user status hyperagent.service 2>/dev/null`
   - Fallback: `pgrep -f "watcher.sh" >/dev/null 2>&1`

2. **Last heartbeat**: Read `<hyperagent_dir>/.heartbeat`. It contains an epoch timestamp updated every watcher loop iteration (every 60 seconds). Calculate how long ago the last heartbeat was. If the file is missing or the heartbeat is older than 5 minutes, the watcher is not running normally.

3. **Last change**: Read `<hyperagent_dir>/.last-change`. Show when the last change was made and what it was.

4. **Recent changelog**: Show the 3 most recent entries from `<hyperagent_dir>/changelog.md` (timestamps and TL;DR lines only).

5. **Watcher log**: Show the last 20 lines of `/tmp/hyperagent.log` if it exists.

Format the output clearly. If the watcher is not running, tell the user how to restart it:
- macOS: `launchctl kickstart -k gui/$(id -u)/com.bioneural.hyperagent`
- Linux: `systemctl --user restart hyperagent.service`
```

### `skills/hyperagent-issue/SKILL.md`

```markdown
---
name: hyperagent-issue
description: File an issue on the Graft repo with system context. Use when the user reports a problem with the hyperagent, or says "file an issue", "report a bug", or similar.
---
# File a Graft Issue

First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

The user wants to report a problem with the hyperagent system. Collect context and file an issue on bioneural/graft.

1. Ask the user to describe the problem if they haven't already. Use $ARGUMENTS if provided.

2. Gather diagnostic context automatically:
   - OS: `uname -s -r`
   - Claude Code version: `claude --version 2>&1`
   - Watcher status: check if `<hyperagent_dir>/.heartbeat` exists and its age
   - Last 5 changelog entries (timestamps and TL;DR only) from `<hyperagent_dir>/changelog.md`
   - Last 20 lines of `/tmp/hyperagent.log` if it exists
   - Whether the meta agent has been modified: `git -C <hyperagent_dir> diff HEAD -- meta_agent.md | head -20`

3. Show the user a preview of the issue title and body. Ask for confirmation before filing.

4. File the issue:
   ```bash
   gh issue create --repo bioneural/graft --title "<title>" --body "<body>"
   ```

5. Show the user the issue URL.

**Body format:**
```
## Description

<user's description>

## Diagnostics

- OS: <os>
- Claude Code: <version>
- Watcher heartbeat: <age or "missing">
- Meta agent modified: <yes/no>

<details>
<summary>Recent changelog</summary>

<last 5 entries>

</details>

<details>
<summary>Watcher log (last 20 lines)</summary>

<log tail or "no log found">

</details>
```
```

### `skills/hyperagent-upgrade/SKILL.md`

```markdown
---
name: hyperagent-upgrade
description: Check the Graft blueprint for updates and contribute local improvements back. Use when the user asks about upgrades, updates, "check for updates", or wants to contribute back to graft.
---
# Hyperagent Upgrade

First, read `~/.claude/hyperagent.json` to get the `hyperagent_dir` path. Use that path for all file references below.

Your hyperagent is an independent implementation generated from the Graft blueprint (`bioneural/graft`). You own it — you can modify anything. This skill reviews upstream blueprint changes you might want to adopt, and identifies local improvements worth contributing back.

## Part 1: Pull from Graft

1. Fetch recent commits from the Graft repo:
   ```bash
   gh api repos/bioneural/graft/commits --jq '.[0:20] | .[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"'
   ```

2. Determine the baseline. Check these in order:
   - `<hyperagent_dir>/.last-upgrade-check` — the last reviewed commit (set by previous upgrade runs)
   - `<hyperagent_dir>/.graft-version` — the graft commit this hyperagent was generated from

   ```bash
   BASELINE=$(cat <hyperagent_dir>/.last-upgrade-check 2>/dev/null || cat <hyperagent_dir>/.graft-version 2>/dev/null)
   ```
   If a baseline exists, only show commits newer than that SHA. If neither file exists, show the 10 most recent.

3. For each new commit, fetch the diff:
   ```bash
   gh api repos/bioneural/graft/commits/<sha> --jq '.files[] | "\(.filename): \(.status) (+\(.additions)/-\(.deletions))"'
   ```

4. Present the changes to the user grouped by type:
   - **Spec changes** (`hyperagent-spec.md`): changes to skill definitions, watcher logic, meta agent behavior, install/uninstall procedures
   - **Implementation guide changes** (`implement-hyperagent.md`): changes to build/validation steps
   - **Other**: README, new files, etc.

5. For each relevant change, analyze whether it applies to the user's hyperagent:
   - Is it a new skill? → Could be added directly.
   - Is it a change to an existing skill? → Compare with the local version and suggest a merge.
   - Is it a watcher or hook change? → Show the diff and explain what it would change.
   - Is it a meta agent change? → The meta agent self-modifies, so flag for the user's judgment.

6. Ask the user which changes (if any) to incorporate. For approved changes:
   - Read the relevant section from the upstream spec: `gh api repos/bioneural/graft/contents/hyperagent-spec.md --jq '.content' | base64 -d`
   - Apply the change to the local hyperagent file.
   - Log the incorporation in `<hyperagent_dir>/changelog.md`.

## Part 2: Contribute Back to Graft

7. Review local changes that diverge from the blueprint. The generation baseline is in `<hyperagent_dir>/.graft-version` — this is the graft commit the hyperagent was originally built from. Compare key files against the upstream spec at that baseline and at HEAD to distinguish local customizations from upstream drift:
   - `meta_agent.md` — has the meta agent evolved strategies worth sharing?
   - `skills/` — any new skills or significant skill improvements?
   - `tools/` — any tools that solve common problems?
   - `watcher.sh`, `hooks/` — any bug fixes or robustness improvements?

   To diff, fetch the upstream version and compare:
   ```bash
   gh api repos/bioneural/graft/contents/hyperagent-spec.md --jq '.content' | base64 -d > /tmp/graft-spec.md
   ```

8. For each meaningful local divergence, assess whether it's:
   - **A bug fix** → worth contributing as an issue or PR
   - **A new capability** (skill, tool, strategy) → worth contributing as an issue describing the idea
   - **A local customization** → specific to this user, skip
   - **A meta agent self-modification** → potentially interesting if it represents a general improvement

9. Present candidates to the user. For each one the user approves:
   - **File as an issue**: Use `/hyperagent-issue` to file on `bioneural/graft` with the local change as context.
   - **Open a PR**: Fork graft (if not already forked), create a branch, apply the change to the spec, and open a PR:
     ```bash
     gh repo fork bioneural/graft --clone=false 2>/dev/null || true
     gh api repos/bioneural/graft/contents/hyperagent-spec.md --jq '.content' | base64 -d > /tmp/graft-spec.md
     ```
     Then guide the user through the PR creation.

## Wrap Up

10. Save the latest reviewed commit SHA:
    ```bash
    echo "<latest_sha>" > <hyperagent_dir>/.last-upgrade-check
    ```

11. Delete the upgrade notification file:
    ```bash
    rm -f <hyperagent_dir>/.upgrade-available
    ```

12. Tell the user to `/hyperagent-reload` to review what changed.

If the user provides arguments: $ARGUMENTS — use them to filter (e.g. "just pull", "just contribute", "last 3 commits", "show everything").
```

---

## 4. What the System Reads and Writes

### Reads (never modifies)

- Session transcripts: `~/.claude/projects/<hash>/sessions/*.jsonl`
- Session index: `~/.claude/projects/<hash>/sessions-index.json` (for resolving project paths)

### Writes — Global (`~/.claude/`)

Files the meta agent may create or modify:

- `~/.claude/CLAUDE.md`
- `~/.claude/skills/<n>/SKILL.md` (skills for the user)
- `~/.claude/agents/<n>.md`
- `~/.claude/rules/<n>.md`

No git repo at `~/.claude/`. The hyperagent's `changelog.md` is the version history for global files. Each changelog entry includes the full diff (before/after) for rollback.

### Writes — Project (`<project>/`)

Files the meta agent may create or modify:

- `<project>/CLAUDE.md`
- `<project>/.claude/skills/<n>/SKILL.md`
- `<project>/.claude/agents/<n>.md`
- `<project>/.claude/rules/<n>.md`
- `<project>/<subdir>/CLAUDE.md`
- `<project>/.claude/hyperagent/tools/` (project-specific meta agent tools)

Project files are committed in the project's own git repo by the watcher after each meta agent cycle (see §6). Author: `Hyperagent <hyperagent@local>`. Message prefix: `[hyperagent]`.

### Writes — Self (`~/hyperagent/`)

- `meta_agent.md` — self-modification
- `memory.md` — insights
- `changelog.md` — audit trail (watcher-driven, see §6)
- `tools/*` — scripts the meta agent creates for itself

Committed in the hyperagent repo by the watcher after each meta agent cycle (see §6).

---

## 5. `meta_agent.md`

The meta agent's definition. Invoked by the watcher via `claude -p`. Self-modifiable. The watcher reads this file fresh from disk each invocation, so self-modifications take effect on the next cycle.

The meta agent does NOT write changelog entries. The watcher handles that (see §6). The meta agent focuses entirely on observation, analysis, and modification.

```markdown
# Meta Agent

You are the meta agent of a self-improving Claude Code system. You run between sessions. Your job is to review how recent Claude Code sessions went, identify what could be better, and modify Claude Code's configuration to improve future sessions.

You can modify this file — your own instructions — if you believe a different approach to observation, diagnosis, or modification would be more effective.

## Input

The watcher sets these environment variables:

- HYPERAGENT_DIR: absolute path to the hyperagent repo
- TRIGGER_TRANSCRIPT: absolute path to the session transcript that triggered this cycle
- RECENT_TRANSCRIPTS: newline-separated absolute paths to transcripts from the last 48 hours

Read your memory from $HYPERAGENT_DIR/memory.md.

## Tool Discovery

Before starting your analysis, list the contents of $HYPERAGENT_DIR/tools/ and read the header comment of each script to understand what tools are available to you. If a tool exists that would help with your current analysis, use it. Tools are invoked via Bash.

For project-specific tools, check <project>/.claude/hyperagent/tools/ if you are analyzing a project transcript.

When you create a new tool, also ensure it is referenced from wherever it needs to be called — this file, a skill you create, another tool, or wherever is appropriate. The tool and the reference to it should be created together.

## Procedure

1. Discover available tools (see above).
2. Read the trigger transcript. Scan recent transcripts for cross-session patterns.
3. Look for signal:
   - User corrections ("no, do it this way", undoing Claude's work, redoing manually)
   - Repeated instructions (user tells Claude the same thing across sessions)
   - Friction (user rephrases multiple times before Claude understands)
   - Missing context (Claude started without enough info, had to backtrack)
   - Successful patterns (things that went well — understand why)
4. Check regression: read memory for recent changes you made. Examine transcripts from sessions AFTER those changes. Did the targeted pattern improve, worsen, or stay the same?
   - If clearly worse: revert. For global files, read the diff from the most recent changelog entries and write the previous content back. For project files, run `git revert` in the project repo filtering by your commits. Note the revert in memory.
   - If ambiguous: keep the change, note uncertainty in memory, check again next cycle.
   - If improved: record the success in memory.
   For rules specifically, go deeper: check whether the rule itself was followed, not just whether the targeted pattern changed. A pattern can improve for unrelated reasons while the rule is ignored. Search post-change transcripts for situations where the rule applied. Classify what happened:
   - **Followed**: the rule visibly influenced Claude's behavior. Record the success.
   - **Not attended to**: the situation arose but Claude showed no awareness of the rule. The rule may be buried in a long file (lost-in-the-middle effect) or drowned out by total rule volume. Consider repositioning it earlier in CLAUDE.md, extracting it to a path-scoped rule with higher signal-to-noise, or consolidating other rules to reduce competition.
   - **Precedence conflict**: Claude's behavior followed the system prompt or training prior instead of the rule. Look for the conflict. If the system prompt contradicts the rule, rewrite with an explicit override clause and reasoning, or accept that this rule cannot be enforced at the prompting layer.
   - **Rationalized away**: Claude acknowledged or reasoned about the rule but constructed a justification for not following it. The rule may be too vague, leaving room for interpretation. Rewrite with specific, observable criteria that leave no room for exception-finding.
   - **Vacuous compliance**: the rule was technically followed because its precondition never triggered, due to an upstream rule or system prompt behavior blocking it. Rewrite as a full causal chain — encode the entire sequence of actions, not just the downstream effect.
   If a rule has been violated across two or more sessions, do not simply re-add or strengthen the wording. Diagnose first, then select the appropriate response from above.
5. Decide whether a new change is warranted. **If you find nothing actionable — no patterns worth acting on, no improvements to make — exit without modifying any files. Do not write "no changes" to memory.md. Do not update any files. A clean exit with no file modifications is the correct response to a cycle with nothing actionable. Most cycles should be silent.**
6. If a change is warranted, make it. See "Where to write" below. When deploying a rule, also record in memory what you expect to observe in future transcripts — what specific behavior should appear or disappear. This is your verification criterion. Without it, step 4 cannot distinguish a followed rule from a coincidental improvement.
7. Update $HYPERAGENT_DIR/memory.md with what you observed, what you changed, your hypothesis, and what to look for next. Only write to memory when you have made a change or have a genuinely new insight worth recording.
8. Write a summary to stdout. Use one of these prefixes so the watcher knows what happened:
   - `NOTIFY_RELOAD: <tl;dr>` — a CLAUDE.md or rules file was changed, user should /hyperagent-reload to review
   - `NOTIFY_SKILL: <tl;dr>` — a skill was created or modified, no reload needed (hot-reload)
   - `NOTIFY_INFO: <tl;dr>` — informational, no action needed from user
   - `NOTIFY_DISCUSS: <tl;dr>` — a discussion document was written, user input requested before the meta agent acts
   - No output if no changes were made.

Note: you do NOT need to write changelog entries. The watcher handles that automatically after you finish.

## Where to write

- Pattern seen across multiple projects → `~/.claude/CLAUDE.md` or `~/.claude/rules/`
- Pattern specific to one project → `<project>/CLAUDE.md` or `<project>/.claude/rules/<topic>.md`
- Pattern specific to a subdirectory → `<project>/<subdir>/CLAUDE.md` or a path-scoped rule
- New reusable behavior for the user → `~/.claude/skills/<n>/SKILL.md` or `<project>/.claude/skills/<n>/SKILL.md`
- New agent → `~/.claude/agents/<n>.md` or `<project>/.claude/agents/<n>.md`
- Tool for your own use across projects → `$HYPERAGENT_DIR/tools/<n>.sh`
- Tool for your own use in one project → `<project>/.claude/hyperagent/tools/<n>.sh`
- Improvement to your own process → this file (`$HYPERAGENT_DIR/meta_agent.md`)

To resolve a project path from a transcript: the transcript is at `~/.claude/projects/<hash>/sessions/<uuid>.jsonl`. Read `~/.claude/projects/<hash>/sessions-index.json` for the project filesystem path. If the index is missing or unreadable, skip project-level changes for that transcript.

For path-scoped rules, use YAML frontmatter:
```yaml
---
paths:
  - "src/api/**/*.ts"
---
```

For skills, use YAML frontmatter:
```yaml
---
name: skill-name
description: When this skill should be invoked
---
```

## What you can modify

- `~/.claude/CLAUDE.md`
- `~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/rules/`
- `<project>/CLAUDE.md`
- `<project>/.claude/skills/`, `<project>/.claude/agents/`, `<project>/.claude/rules/`
- `<project>/<subdirectory>/CLAUDE.md`
- `<project>/.claude/hyperagent/tools/`
- `$HYPERAGENT_DIR/meta_agent.md` (this file)
- `$HYPERAGENT_DIR/memory.md`
- `$HYPERAGENT_DIR/tools/`
- `$HYPERAGENT_DIR/discussions/`

## What you must never modify

- Session transcripts under `~/.claude/projects/`
- `$HYPERAGENT_DIR/watcher.sh`
- `$HYPERAGENT_DIR/hooks/`
- `$HYPERAGENT_DIR/changelog.md` (the watcher owns this)
- `$HYPERAGENT_DIR/ledger`
- `$HYPERAGENT_DIR/.last-check`
- `$HYPERAGENT_DIR/.lock`
- `$HYPERAGENT_DIR/.last-change`
- `$HYPERAGENT_DIR/.seen/`
- `$HYPERAGENT_DIR/install.sh`
- `$HYPERAGENT_DIR/uninstall.sh`
- `$HYPERAGENT_DIR/skills/` (the shipped skills)

## Signal discovery

You start knowing only about session transcripts. Over time you will see evidence of other signal sources — PR comments, issue trackers, CI results. When you discover one:

1. Record it in memory: what it is, how you found it, how to access it (MCP server name if available).
2. On future cycles, try to use it. If the MCP server is connected, query it. If not, note that in memory and work with whatever signal appears in transcripts.
3. Consider building a tool in $HYPERAGENT_DIR/tools/ to automate querying the signal source, and ensure it is referenced from wherever it needs to be called.

## Filing issues on Graft

If you encounter a problem you cannot resolve — a spec inconsistency, a Claude CLI behavior change that breaks your assumptions, a transcript format change, or a pattern you believe is a bug in the hyperagent system itself — you may file an issue on the Graft repo.

```bash
gh issue create --repo bioneural/graft \
    --title "<concise title>" \
    --body "<description with diagnostics>"
```

Include in the body: what you observed, what you expected, the OS (`uname -s -r`), Claude Code version (`claude --version`), and any relevant log output or transcript excerpts.

**Constraints:**
- Check for duplicates first: `gh issue list --repo bioneural/graft --search "<keywords>" --state open`
- Do not file more than one issue per cycle.
- Do not file issues about user-specific preferences or project-specific patterns. Only file issues about the hyperagent system itself.
- Record in memory that you filed an issue, including the issue number, so you don't file duplicates on subsequent cycles.

## Housekeeping

When memory.md exceeds 200 lines, consolidate: summarize entries older than 2 weeks into a compact section at the top, remove their raw detail. Keep recent entries intact. You may change this heuristic.

## Starting heuristics

Modify these if you learn something better.

- Prefer one focused change per cycle for clean attribution and rollback.
- Prefer small, targeted modifications over wholesale rewrites.
- Act on patterns seen 3+ times across sessions. Record patterns seen fewer times as hypotheses.
- Not every cycle needs to produce a change.

### Rule authoring

- Write rules as explanatory prose, not bare directives. Include *why* the rule exists. A rule that carries its own reasoning is more reliably internalized than one that demands compliance without context.
- Be specific and verifiable. "Use 2-space indentation" is followed more reliably than "format code properly." If you cannot describe what compliance looks like in a transcript, the rule is too vague.
- Prefer positive instructions ("do X") over prohibitions ("don't do Y"). Negative rules require the model to infer desired behavior from excluded behavior.
- Position matters. Rules at the beginning or end of a CLAUDE.md file receive more model attention than rules buried in the middle. Place high-priority rules accordingly.
- Manage total rule surface area. Each additional rule competes with existing rules for attention. When deploying a new rule, check whether existing rules can be consolidated or retired. A smaller set of clear rules outperforms a large set of overlapping ones.
- Before deploying a rule, check for conflicts with the Claude Code system prompt. Rules that contradict the system prompt will lose unless they include explicit override reasoning. Known system prompt behaviors include: do not commit unless asked, do not push unless asked, confirm before destructive operations, prefer dedicated tools over bash equivalents.
- When a rule must override a system prompt default, state this explicitly in the rule and explain why the override is appropriate for this user or project.

### Conversation protocol

Not every intervention should be auto-applied. The meta agent distinguishes between lightweight and heavyweight changes and chooses the appropriate mode.

**When to discuss vs. auto-apply.** Lightweight interventions — adjusting rule wording, adding a gotcha, refining a skill description — can be applied directly. Heavyweight interventions — introducing new behavioral rules, self-modification, changes that alter how the user or Claude Code operates in a fundamental way — default to discussion. If an intervention vocabulary exists (see tools or memory), use its weight classification to make this determination.

**Discussion documents.** When discussion is warranted, the meta agent writes a document to `$HYPERAGENT_DIR/discussions/<topic>.md`. The document contains:

- Synthesized evidence across occurrences. Not "seen 3x" — what is common across instances, what differs, what the trajectory looks like.
- A point of view on root cause. The meta agent states what it believes is happening and why.
- Tradeoff analysis. Why might the current behavior sometimes be correct? What would be lost by changing it?
- One or more proposed interventions with reasoning. Each proposal includes what it would change, what it expects to improve, and what it might break.

The meta agent outputs `NOTIFY_DISCUSS: <one-line summary>` so the watcher can signal the user.

**Feedback loop.** On subsequent cycles, the meta agent checks recent transcripts for responses that reference its discussion topics. It reads the human's perspective and incorporates it into its remediation decision. The discussion document is updated with the outcome — what was decided, what was acted on, and why.

**Staleness.** If the user does not respond within a reasonable window, the meta agent does not escalate or nag. Silence is data. The meta agent records the open discussion in memory and moves on. The topic remains available if the user engages later, but no further notifications are sent about it.
```

---

## 6. `watcher.sh`

The watcher is fixed infrastructure. The meta agent cannot modify it. It must work on Linux and macOS without modification.

The watcher has four responsibilities:

1. **Trigger the meta agent** when sessions go idle.
2. **Drive changelog entries.** After the meta agent completes, the watcher checks whether any files changed. If so, it resumes the meta agent's session to write the changelog entry.
3. **Enforce git commits.** After the changelog entry is written, the watcher commits all changes in both the hyperagent repo and any affected project repos.
4. **Signal active sessions.** After committing, the watcher writes a `.last-change` file that the hooks read to notify the user. It also periodically cleans up stale `.seen/` files.

```bash
#!/usr/bin/env bash
set -euo pipefail

HYPERAGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_DIR="$HOME/.claude/projects"
LEDGER="$HYPERAGENT_DIR/ledger"
MARKER="$HYPERAGENT_DIR/.last-check"
LOCKFILE="$HYPERAGENT_DIR/.lock"
LAST_CHANGE="$HYPERAGENT_DIR/.last-change"
HEARTBEAT="$HYPERAGENT_DIR/.heartbeat"
SEEN_DIR="$HYPERAGENT_DIR/.seen"
CHANGELOG="$HYPERAGENT_DIR/changelog.md"
IDLE_THRESHOLD=300
CHECK_INTERVAL=60
MAX_TRANSCRIPTS_PER_CYCLE="${MAX_TRANSCRIPTS_PER_CYCLE:-5}"
META_AGENT="$HYPERAGENT_DIR/meta_agent.md"
UPGRADE_AVAILABLE="$HYPERAGENT_DIR/.upgrade-available"
UPGRADE_CHECK_INTERVAL="${UPGRADE_CHECK_INTERVAL:-3600}"  # 1 hour
CONSECUTIVE_FAILURES=0
LAST_FAILURE_MSG=""
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"

# Verify we are a top-level repo, not nested inside another project
REPO_TOPLEVEL=$(git -C "$HYPERAGENT_DIR" rev-parse --show-toplevel 2>/dev/null) || true
if [ -n "$REPO_TOPLEVEL" ] && [ "$REPO_TOPLEVEL" != "$HYPERAGENT_DIR" ]; then
    echo "FATAL: HYPERAGENT_DIR ($HYPERAGENT_DIR) is inside another git repo ($REPO_TOPLEVEL)." >&2
    echo "The hyperagent must be its own top-level repo. Reinstall at a standalone path." >&2
    exit 1
fi

touch "$LEDGER" "$MARKER"
mkdir -p "$SEEN_DIR"

get_mtime() {
    if stat --version >/dev/null 2>&1; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

now_epoch() {
    date +%s
}

is_locked() {
    if [ -f "$LOCKFILE" ]; then
        local pid
        pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$LOCKFILE"
            return 1
        fi
    fi
    return 1
}

acquire_lock() { echo $$ > "$LOCKFILE"; }
release_lock() { rm -f "$LOCKFILE"; }

get_ledger_entry() {
    grep -F "$1" "$LEDGER" 2>/dev/null | tail -1 || echo ""
}

set_ledger_entry() {
    local path="$1" processed_mtime="$2" first_idle="$3"
    grep -vF "$path" "$LEDGER" > "$LEDGER.tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$path" "$processed_mtime" "$first_idle" >> "$LEDGER.tmp"
    mv "$LEDGER.tmp" "$LEDGER"
}

get_recent_transcripts() {
    find "$PROJECTS_DIR" -name "*.jsonl" -mmin -2880 -type f 2>/dev/null | head -20
}

resolve_project_path() {
    local transcript="$1"
    local project_dir
    project_dir=$(echo "$transcript" | sed 's|/sessions/.*||')
    local index="$project_dir/sessions-index.json"
    if [ -f "$index" ]; then
        jq -r '
            if type == "array" then .[0] else . end |
            (.project_path // .path // .cwd // empty)
        ' "$index" 2>/dev/null || echo ""
    fi
}

pull_fast_forward() {
    local repo_dir="$1"
    if [ -z "$repo_dir" ] || [ ! -d "$repo_dir/.git" ]; then
        return
    fi
    cd "$repo_dir"
    git fetch 2>/dev/null || true
    git merge --ff-only 2>/dev/null || true
}

commit_hyperagent_repo() {
    local tl_dr="$1"
    cd "$HYPERAGENT_DIR"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -A
        git commit --author="Hyperagent <hyperagent@local>" \
            -m "[hyperagent] ${tl_dr:-auto-commit}" \
            2>/dev/null || true
        git push 2>/dev/null || true
    fi
}

commit_project_repo() {
    local project_path="$1"
    local tl_dr="$2"
    if [ -z "$project_path" ] || [ ! -d "$project_path/.git" ]; then
        return
    fi
    cd "$project_path"
    pull_fast_forward "$project_path"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -A
        git commit --author="Hyperagent <hyperagent@local>" \
            -m "[hyperagent] ${tl_dr:-auto-commit}" \
            2>/dev/null || true
    fi
}

write_last_change() {
    local notify_type="$1"
    local tl_dr="$2"
    local now
    now=$(now_epoch)
    printf '%s\t%s\t%s\n' "$now" "$notify_type" "$tl_dr" > "$LAST_CHANGE"
}

cleanup_seen() {
    # Remove .seen files older than 48 hours
    find "$SEEN_DIR" -type f -mmin +2880 -delete 2>/dev/null || true
}

check_upstream_upgrade() {
    # Determine when we last polled upstream
    local last_poll=0
    if [ -f "$HYPERAGENT_DIR/.last-upstream-poll" ]; then
        last_poll=$(get_mtime "$HYPERAGENT_DIR/.last-upstream-poll")
    fi
    local now
    now=$(now_epoch)
    if [ $((now - last_poll)) -lt "$UPGRADE_CHECK_INTERVAL" ]; then
        return
    fi

    # Record that we polled, regardless of outcome
    touch "$HYPERAGENT_DIR/.last-upstream-poll"

    # Determine baseline SHA
    local baseline=""
    if [ -f "$HYPERAGENT_DIR/.last-upgrade-check" ]; then
        baseline=$(cat "$HYPERAGENT_DIR/.last-upgrade-check" 2>/dev/null || echo "")
    elif [ -f "$HYPERAGENT_DIR/.graft-version" ]; then
        baseline=$(cat "$HYPERAGENT_DIR/.graft-version" 2>/dev/null || echo "")
    fi

    # Fetch latest graft commit SHA (fail silently on network errors)
    local latest
    latest=$(gh api repos/bioneural/graft/commits/main --jq '.sha' 2>/dev/null) || return
    if [ -z "$latest" ]; then
        return
    fi

    # Compare and write notification if different
    if [ "$latest" != "$baseline" ]; then
        printf '%s\t%s\n' "$now" "New commits on bioneural/graft since last upgrade check" > "$UPGRADE_AVAILABLE"
    fi
}

cleanup_ledger() {
    # Remove ledger entries for transcripts not modified in 48+ hours
    # that have already been successfully processed
    local tmp_ledger="$LEDGER.tmp"
    local now
    now=$(now_epoch)
    local cutoff=$((now - 172800))  # 48 hours

    while IFS=$'\t' read -r path current_mtime processed_mtime; do
        # Keep if processed_mtime differs from current_mtime (not yet processed)
        if [ "$current_mtime" != "$processed_mtime" ]; then
            printf '%s\t%s\t%s\n' "$path" "$current_mtime" "$processed_mtime" >> "$tmp_ledger"
            continue
        fi
        # Keep if modified recently
        if [ "$current_mtime" -gt "$cutoff" ] 2>/dev/null; then
            printf '%s\t%s\t%s\n' "$path" "$current_mtime" "$processed_mtime" >> "$tmp_ledger"
        fi
    done < "$LEDGER"

    if [ -f "$tmp_ledger" ]; then
        mv "$tmp_ledger" "$LEDGER"
    else
        : > "$LEDGER"
    fi
}

run_meta_agent() {
    local trigger_transcript="$1"
    local recent
    recent=$(get_recent_transcripts)

    # --- Phase 1: Meta agent does its work ---

    local output
    # 45-minute timeout prevents hung processes from holding the lock indefinitely.
    # Start a background watchdog that kills the claude process after 2700 seconds.
    local watchdog_pid
    ( sleep 2700 && kill $$ 2>/dev/null ) &
    watchdog_pid=$!

    output=$(HYPERAGENT_DIR="$HYPERAGENT_DIR" \
        TRIGGER_TRANSCRIPT="$trigger_transcript" \
        RECENT_TRANSCRIPTS="$recent" \
        claude -p "Read your instructions from $META_AGENT and execute your procedure." \
            --allowedTools "Read,Write,Edit,Bash,Glob,Grep" \
            --output-format json \
            2>/dev/null) || true

    # Cancel the watchdog if we finished in time
    kill "$watchdog_pid" 2>/dev/null || true

    # Extract session ID and notify line
    local session_id
    session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null || echo "")

    local result_text
    result_text=$(echo "$output" | jq -r '.result // empty' 2>/dev/null || echo "")

    local notify_line
    notify_line=$(echo "$result_text" | grep -E "^NOTIFY_(RELOAD|SKILL|INFO|DISCUSS):" | head -1 || echo "")

    local tl_dr
    tl_dr=$(echo "$notify_line" | sed 's/^NOTIFY_[A-Z]*: //')

    local notify_type=""
    if echo "$notify_line" | grep -q "^NOTIFY_RELOAD:"; then
        notify_type="reload"
    elif echo "$notify_line" | grep -q "^NOTIFY_SKILL:"; then
        notify_type="skill"
    elif echo "$notify_line" | grep -q "^NOTIFY_INFO:"; then
        notify_type="info"
    elif echo "$notify_line" | grep -q "^NOTIFY_DISCUSS:"; then
        notify_type="discuss"
    fi

    # --- Phase 2: Check if anything changed ---

    local hyperagent_changed=""
    cd "$HYPERAGENT_DIR"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        hyperagent_changed="yes"
    fi

    local project_path
    project_path=$(resolve_project_path "$trigger_transcript")
    local project_changed=""
    if [ -n "$project_path" ] && [ -d "$project_path/.git" ]; then
        cd "$project_path"
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            project_changed="yes"
        fi
    fi

    # --- Phase 3: Drive changelog entry if anything changed ---

    if [ -n "$hyperagent_changed" ] || [ -n "$project_changed" ]; then
        local diff_summary=""
        if [ -n "$hyperagent_changed" ]; then
            cd "$HYPERAGENT_DIR"
            diff_summary="${diff_summary}$(git diff 2>/dev/null || true)"
            diff_summary="${diff_summary}$(git diff --cached 2>/dev/null || true)"
        fi
        if [ -n "$project_changed" ] && [ -n "$project_path" ]; then
            cd "$project_path"
            diff_summary="${diff_summary}$(git diff 2>/dev/null || true)"
        fi

        if [ -n "$session_id" ]; then
            claude -p "You just made changes. Write a changelog entry and append it to $CHANGELOG.

Use this exact format:

## $(date -u +%Y-%m-%dT%H:%M:%SZ)

**TL;DR:** $tl_dr

**Target:** <absolute file path(s) you modified>

**Type:** <global|project|self>

**Diff:**
\`\`\`
< previous content of modified section
---
> new content of modified section
\`\`\`

**Reasoning:** <what pattern triggered this, what you expect to improve>

---

Here is the git diff of your changes for reference:

$diff_summary" \
                --resume "$session_id" \
                --allowedTools "Read,Write,Edit" \
                2>/dev/null || true
        fi

        # --- Phase 4: Commit everything ---

        commit_hyperagent_repo "$tl_dr"

        if [ -n "$project_changed" ] && [ -n "$project_path" ]; then
            commit_project_repo "$project_path" "$tl_dr"
        fi

        # --- Phase 5: Signal active sessions ---

        if [ -n "$notify_type" ]; then
            write_last_change "$notify_type" "$tl_dr"
        fi
    fi

    # Periodic cleanup
    cleanup_seen
    cleanup_ledger
}

is_own_transcript() {
    local transcript_path="$1"
    local encoded_dir
    encoded_dir=$(echo "$HYPERAGENT_DIR" | sed 's|/|-|g' | sed 's|^-||')
    echo "$transcript_path" | grep -q "$encoded_dir"
}

# --- Main loop ---

while true; do
    # Write heartbeat so hooks and /hyperagent-status can detect a stalled watcher
    date +%s > "$HEARTBEAT"

    # Pull remote changes so the watcher operates on up-to-date state
    pull_fast_forward "$HYPERAGENT_DIR"

    # Periodic upstream upgrade check
    check_upstream_upgrade

    modified=$(find "$PROJECTS_DIR" -name "*.jsonl" -newer "$MARKER" -type f 2>/dev/null || true)
    touch "$MARKER"

    now=$(now_epoch)

    all_transcripts=$(
        echo "$modified"
        awk -F'\t' '{print $1}' "$LEDGER" 2>/dev/null
    )
    all_transcripts=$(echo "$all_transcripts" | sort -u | grep -v '^$' || true)

    processed_this_cycle=0

    for transcript in $all_transcripts; do
        [ -f "$transcript" ] || continue

        if [ "$processed_this_cycle" -ge "$MAX_TRANSCRIPTS_PER_CYCLE" ]; then
            log "Cycle cap reached ($MAX_TRANSCRIPTS_PER_CYCLE), deferring remaining transcripts"
            break
        fi

        # Skip transcripts from the hyperagent's own project directory
        if is_own_transcript "$transcript"; then
            continue
        fi

        current_mtime=$(get_mtime "$transcript")
        entry=$(get_ledger_entry "$transcript")
        processed_mtime=$(echo "$entry" | awk -F'\t' '{print $2}')
        first_idle=$(echo "$entry" | awk -F'\t' '{print $3}')

        if echo "$modified" | grep -qF "$transcript"; then
            set_ledger_entry "$transcript" "${processed_mtime:-0}" "0"
            continue
        fi

        if [ "${first_idle:-0}" = "0" ]; then
            set_ledger_entry "$transcript" "${processed_mtime:-0}" "$now"
            continue
        fi

        idle_duration=$((now - first_idle))
        if [ "$idle_duration" -lt "$IDLE_THRESHOLD" ]; then
            continue
        fi

        if [ "${processed_mtime:-0}" = "$current_mtime" ]; then
            continue
        fi

        if is_locked; then
            continue
        fi

        acquire_lock

        if run_meta_agent "$transcript"; then
            CONSECUTIVE_FAILURES=0
            LAST_FAILURE_MSG=""
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            LAST_FAILURE_MSG=$(tail -1 /tmp/hyperagent.log 2>/dev/null || echo "unknown error")
            if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
                write_last_change "error" "Meta agent has failed $CONSECUTIVE_FAILURES consecutive times: $LAST_FAILURE_MSG. Run /hyperagent-status for details."
                echo "$(date): Circuit breaker tripped after $CONSECUTIVE_FAILURES consecutive failures" >> /tmp/hyperagent.log
                release_lock
                set_ledger_entry "$transcript" "$current_mtime" "0"
                break
            fi
        fi

        release_lock

        set_ledger_entry "$transcript" "$current_mtime" "0"
        processed_this_cycle=$((processed_this_cycle + 1))
        date +%s > "$HEARTBEAT"
    done

    sleep "$CHECK_INTERVAL"
done
```

Mark executable: `chmod +x watcher.sh`

---

## 7. `memory.md`

Initial contents:

```markdown
# Meta Agent Memory

Accumulated insights across cycles. Read at the start of each cycle, updated at the end.

## Skill Best Practices

Lessons from Anthropic's internal skill management (source: "Lessons from Building Claude Code: How We Use Skills" by Thariq, Mar 2026). Apply these when creating or modifying skills:

- **Description field is a trigger condition.** The model scans it to decide relevance. Write "use when X", not a human summary. Poorly written descriptions cause hallucinated skill selections.
- **Progressive disclosure via folder structure.** Complex skills benefit from subdirectories (references/, scripts/, examples/) alongside SKILL.md. The agent reads sub-files on demand rather than loading everything into context. Reduces token usage.
- **Gotchas sections are the highest-signal content.** Build them from actual agent failure modes. Update them over time. A skill without gotchas is a skill that hasn't been tested enough.
- **Script composition pattern.** Bundle helper functions/libraries in skills so the agent composes them rather than reconstructing boilerplate each time.
- **Nine skill categories exist:** Library/API Reference, Product Verification, Data Fetching/Analysis, Business Process Automation, Code Scaffolding, Code Quality/Review, CI/CD & Deployment, Runbooks, Infrastructure Operations. Useful for identifying coverage gaps when the skill count grows.
- **On-demand hooks.** Skills can register hooks that activate only when invoked and last for the session (e.g., block destructive commands, restrict edits to a directory). Consider when building safety-critical skills.
- **Measure skill usage.** Track invocations to find skills that are popular or undertriggering. The transcript already captures this signal — mine it.
- **Persistent skill memory.** Skills may need cross-session state (logs, JSON, SQLite). Consider when building skills that learn from repeated use.
- **Curation before distribution.** Experimental skills should prove their value before becoming permanent. Remove or consolidate skills that underperform.

## Rule Effectiveness

Lessons from instruction-following research. Apply these when creating or evaluating rules:

- **The instruction budget is finite and smaller than it appears.** Each rule competes with every other rule and with the system prompt for model attention. Degradation begins at single-digit constraint counts and worsens with each addition. Treat total rule surface area as a resource to be managed, not a list to be appended to.
- **Position determines attention.** Rules in the middle of a long file receive less model attention than rules at the beginning or end (Liu et al., "Lost in the Middle," TACL 2024). When a rule is not being followed, repositioning it may be more effective than rewriting it.
- **Explanatory prose outperforms directives.** Anthropic's own alignment work moved from standalone principles to explanatory prose because models internalize rules more reliably when they understand the reasoning. Write "Do X because Y" rather than "Do X."
- **The system prompt holds structural precedence.** When a user rule conflicts with a system prompt instruction, the system prompt wins — not by merit but by position and framing. Rules that must override a system prompt default need explicit override clauses with reasoning, or they will be silently ignored.
- **Verify rule adherence, not just pattern improvement.** A pattern can improve for unrelated reasons while the rule is ignored. After deploying a rule, record what should change in future transcripts and check specifically for compliance on subsequent cycles.
- **Diagnose before rewriting.** A violated rule may be poorly positioned, in conflict with the system prompt, too vague, phrased as a downstream effect with a blocked precondition, or drowned out by rule volume. Each failure mode has a different fix. Adding emphasis or repeating the rule does not address any of them.
- **Consolidate and retire.** When adding a rule, check whether existing rules overlap, conflict, or have served their purpose. A rule that prevents a pattern no longer occurring in transcripts is consuming budget for no benefit.

## Gotchas

- **Do not maintain a cycle counter or per-cycle bookkeeping.** In early runs the meta agent invented a cycle counter in this file, bumping it every cycle even with no findings. Because the watcher commits whenever `git status --porcelain` is non-empty, this produced 63 consecutive no-op commits and 1,142 lines of changelog noise. Step 5 of the procedure means it: if nothing is actionable, do not touch any file — including this one. A silent exit is correct.

## Observations

_No observations yet._
```

---

## 8. `changelog.md`

Initial contents:

```markdown
# Hyperagent Changelog
```

The meta agent does not write to this file directly. The watcher drives changelog entries by resuming the meta agent's session after it completes its work (see §6). `changelog.md` is listed in the meta agent's "must never modify" section.

---

## 9. Hooks

Two hooks notify the user of hyperagent changes. They use Claude Code's hook system — lightweight bash scripts registered in `~/.claude/settings.json` that fire at lifecycle events. No MCP server, no additional runtime.

The notification mechanism:

1. After committing changes, the watcher writes `~/hyperagent/.last-change` containing: epoch timestamp, notification type (`reload`/`skill`/`info`/`discuss`/`error`), and TL;DR, tab-separated on one line.
2. Each hook receives `session_id` in its JSON input. It compares the `.last-change` timestamp against a per-session file at `~/hyperagent/.seen/<session_id>`. If the change is newer than what the session last saw (or the session has no `.seen` file), the hook injects a notification and updates the `.seen` file.
3. The watcher periodically cleans `.seen/` files older than 48 hours.

### `hooks/on-session-start.sh`

Fires on session startup, resume, clear, and compact.

```bash
#!/usr/bin/env bash
HYPERAGENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAST_CHANGE="$HYPERAGENT_DIR/.last-change"
UPGRADE_AVAILABLE="$HYPERAGENT_DIR/.upgrade-available"
HEARTBEAT="$HYPERAGENT_DIR/.heartbeat"
SEEN_DIR="$HYPERAGENT_DIR/.seen"

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    exit 0
fi

# --- Watcher heartbeat check ---
WATCHER_DOWN=""
if [ ! -f "$HEARTBEAT" ]; then
    WATCHER_DOWN="yes"
else
    BEAT_EPOCH=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    BEAT_AGE=$(( NOW_EPOCH - BEAT_EPOCH ))
    if [ "$BEAT_AGE" -gt 300 ]; then
        WATCHER_DOWN="yes"
    fi
fi

if [ -n "$WATCHER_DOWN" ]; then
    echo "{\"additionalContext\": \"[Hyperagent] WARNING: watcher is not running. Run /hyperagent-status for details.\"}"
fi

# --- Upgrade available check ---
if [ -f "$UPGRADE_AVAILABLE" ]; then
    mkdir -p "$SEEN_DIR"
    if [ ! -f "$SEEN_DIR/$SESSION_ID.upgrade" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] Graft blueprint updates available. Run /hyperagent-upgrade to review.\"}"
        touch "$SEEN_DIR/$SESSION_ID.upgrade"
    fi
fi

if [ ! -f "$LAST_CHANGE" ]; then
    exit 0
fi

mkdir -p "$SEEN_DIR"

# Read last change
CHANGE_EPOCH=$(awk -F'\t' '{print $1}' "$LAST_CHANGE")
CHANGE_TYPE=$(awk -F'\t' '{print $2}' "$LAST_CHANGE")
CHANGE_TLDR=$(awk -F'\t' '{print $3}' "$LAST_CHANGE")

# Read last seen epoch for this session
SEEN_EPOCH=0
if [ -f "$SEEN_DIR/$SESSION_ID" ]; then
    SEEN_EPOCH=$(cat "$SEEN_DIR/$SESSION_ID")
fi

# If the change is newer than what this session has seen, notify
if [ "$CHANGE_EPOCH" -gt "$SEEN_EPOCH" ] 2>/dev/null; then
    echo "$CHANGE_EPOCH" > "$SEEN_DIR/$SESSION_ID"

    if [ "$CHANGE_TYPE" = "reload" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Run /hyperagent-reload to review, /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "skill" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Already available (no reload needed). /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "error" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] WARNING: $CHANGE_TLDR\"}"
    elif [ "$CHANGE_TYPE" = "discuss" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Analysis written — your input is requested. See /hyperagent-status for details.\"}"
    else
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. /hyperagent-changelog for details.\"}"
    fi
fi

exit 0
```

### `hooks/on-prompt.sh`

Fires on every `UserPromptSubmit`. Same logic as `on-session-start.sh` — checks `.last-change` against the session's `.seen` file and verifies the watcher heartbeat. This catches mid-session notifications: the very next message you send after the watcher commits a change, you're told about it. It also detects if the watcher has gone down since the session started.

```bash
#!/usr/bin/env bash
HYPERAGENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAST_CHANGE="$HYPERAGENT_DIR/.last-change"
UPGRADE_AVAILABLE="$HYPERAGENT_DIR/.upgrade-available"
HEARTBEAT="$HYPERAGENT_DIR/.heartbeat"
SEEN_DIR="$HYPERAGENT_DIR/.seen"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    exit 0
fi

# --- Watcher heartbeat check ---
WATCHER_DOWN=""
if [ ! -f "$HEARTBEAT" ]; then
    WATCHER_DOWN="yes"
else
    BEAT_EPOCH=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    BEAT_AGE=$(( NOW_EPOCH - BEAT_EPOCH ))
    if [ "$BEAT_AGE" -gt 300 ]; then
        WATCHER_DOWN="yes"
    fi
fi

if [ -n "$WATCHER_DOWN" ]; then
    echo "{\"additionalContext\": \"[Hyperagent] WARNING: watcher is not running. Run /hyperagent-status for details.\"}"
fi

# --- Upgrade available check ---
if [ -f "$UPGRADE_AVAILABLE" ]; then
    mkdir -p "$SEEN_DIR"
    if [ ! -f "$SEEN_DIR/$SESSION_ID.upgrade" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] Graft blueprint updates available. Run /hyperagent-upgrade to review.\"}"
        touch "$SEEN_DIR/$SESSION_ID.upgrade"
    fi
fi

if [ ! -f "$LAST_CHANGE" ]; then
    exit 0
fi

mkdir -p "$SEEN_DIR"

CHANGE_EPOCH=$(awk -F'\t' '{print $1}' "$LAST_CHANGE")
CHANGE_TYPE=$(awk -F'\t' '{print $2}' "$LAST_CHANGE")
CHANGE_TLDR=$(awk -F'\t' '{print $3}' "$LAST_CHANGE")

SEEN_EPOCH=0
if [ -f "$SEEN_DIR/$SESSION_ID" ]; then
    SEEN_EPOCH=$(cat "$SEEN_DIR/$SESSION_ID")
fi

if [ "$CHANGE_EPOCH" -gt "$SEEN_EPOCH" ] 2>/dev/null; then
    echo "$CHANGE_EPOCH" > "$SEEN_DIR/$SESSION_ID"

    if [ "$CHANGE_TYPE" = "reload" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Run /hyperagent-reload to review, /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "skill" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Already available (no reload needed). /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "error" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] WARNING: $CHANGE_TLDR\"}"
    elif [ "$CHANGE_TYPE" = "discuss" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Analysis written — your input is requested. See /hyperagent-status for details.\"}"
    else
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. /hyperagent-changelog for details.\"}"
    fi
fi

exit 0
```

Mark both executable: `chmod +x hooks/on-session-start.sh hooks/on-prompt.sh`

---

## 10. `install.sh`

Installs integration points into `~/.claude/`. Idempotent.

```bash
#!/usr/bin/env bash
set -euo pipefail

HYPERAGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# --- TCC directory check (macOS) ---
check_tcc_safe() {
    if [ "$(uname)" != "Darwin" ]; then return 0; fi
    local resolved
    resolved=$(cd "$1" 2>/dev/null && pwd -P || echo "$1")
    case "$resolved" in
        "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
            echo "ERROR: $1 is under a macOS TCC-protected directory."
            echo "LaunchAgents cannot access ~/Desktop, ~/Documents, or ~/Downloads."
            echo "Use a path outside these directories, e.g. ~/hyperagent"
            exit 1
            ;;
    esac
}
check_tcc_safe "$HYPERAGENT_DIR"

# --- Nested repo check ---
check_not_nested_repo() {
    local toplevel
    toplevel=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
    if [ "$toplevel" != "$1" ]; then
        echo "ERROR: $1 is inside another git repository ($toplevel)."
        echo "The hyperagent must be its own top-level repo."
        echo "Install at a standalone path, e.g. ~/hyperagent"
        exit 1
    fi
}
check_not_nested_repo "$HYPERAGENT_DIR"

echo "=== Installing Hyperagent ==="

# Prerequisites
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found."; exit 1; }

# Create runtime files (not committed)
touch "$HYPERAGENT_DIR/ledger"
touch "$HYPERAGENT_DIR/.last-check"
mkdir -p "$HYPERAGENT_DIR/.seen"

# Create tools directory if not present
mkdir -p "$HYPERAGENT_DIR/tools"

# Make scripts executable
chmod +x "$HYPERAGENT_DIR/watcher.sh"
chmod +x "$HYPERAGENT_DIR/hooks/on-session-start.sh"
chmod +x "$HYPERAGENT_DIR/hooks/on-prompt.sh"

# --- Write config file with resolved path ---

echo "{\"hyperagent_dir\": \"$HYPERAGENT_DIR\"}" > "$CLAUDE_DIR/hyperagent.json"
echo "Wrote config: $CLAUDE_DIR/hyperagent.json"

# --- Symlink skills into ~/.claude/skills/ ---

mkdir -p "$CLAUDE_DIR/skills"

for skill_dir in "$HYPERAGENT_DIR/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    target="$CLAUDE_DIR/skills/$skill_name"

    # Symlink the skill directory
    if [ -L "$target" ]; then
        rm "$target"
    fi
    if [ ! -e "$target" ]; then
        ln -s "$skill_dir" "$target"
        echo "Linked skill: /$skill_name"
    fi
done

# --- Register hooks in ~/.claude/settings.json ---

SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
fi

# Remove any existing hyperagent hooks, then add fresh ones
HOOK_SESSION='{"hooks":[{"type":"command","command":"'"$HYPERAGENT_DIR"'/hooks/on-session-start.sh","timeout":5}]}'
HOOK_PROMPT='{"hooks":[{"type":"command","command":"'"$HYPERAGENT_DIR"'/hooks/on-prompt.sh","timeout":5}]}'

jq --argjson hs "$HOOK_SESSION" --argjson hp "$HOOK_PROMPT" '
    .hooks //= {} |
    .hooks.SessionStart = [
        (.hooks.SessionStart // [] | [.[] | select(
            (.hooks // [] | all(.command | contains("hyperagent") | not))
        )])[],
        $hs
    ] |
    .hooks.UserPromptSubmit = [
        (.hooks.UserPromptSubmit // [] | [.[] | select(
            (.hooks // [] | all(.command | contains("hyperagent") | not))
        )])[],
        $hp
    ]
' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"

echo "Registered hooks: SessionStart, UserPromptSubmit"

# --- Install watcher as a system service ---

if [ "$(uname)" = "Darwin" ]; then
    # macOS: launchd
    PLIST="$HOME/Library/LaunchAgents/com.bioneural.hyperagent.plist"
    cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bioneural.hyperagent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HYPERAGENT_DIR/watcher.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$HYPERAGENT_DIR</string>
    <key>StandardOutPath</key>
    <string>/tmp/hyperagent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/hyperagent.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$PATH</string>
    </dict>
</dict>
</plist>
PLISTEOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "Watcher started (launchd: com.bioneural.hyperagent)"
else
    # Linux: systemd user service
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/hyperagent.service" << UNITEOF
[Unit]
Description=Hyperagent watcher for Claude Code
After=default.target

[Service]
Type=simple
ExecStart=$HYPERAGENT_DIR/watcher.sh
WorkingDirectory=$HYPERAGENT_DIR
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNITEOF
    systemctl --user daemon-reload
    systemctl --user enable hyperagent.service
    systemctl --user restart hyperagent.service
    echo "Watcher started (systemd: hyperagent.service)"
fi

# --- Initial commit if repo not yet initialized ---

if [ ! -d "$HYPERAGENT_DIR/.git" ]; then
    git -C "$HYPERAGENT_DIR" init
    git -C "$HYPERAGENT_DIR" add -A
    git -C "$HYPERAGENT_DIR" commit --author="Hyperagent <hyperagent@local>" \
        -m "[hyperagent] initial install"
fi

echo ""
echo "=== Hyperagent installed ==="
echo ""
echo "The watcher is running as a system service."
echo "Restart Claude Code to pick up the new hooks."
```

Mark executable: `chmod +x install.sh`

---

## 11. `uninstall.sh`

Removes everything `install.sh` added. Does not delete the hyperagent repo.

```bash
#!/usr/bin/env bash
set -euo pipefail

HYPERAGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "=== Uninstalling Hyperagent ==="

# Stop and remove watcher service
if [ "$(uname)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.bioneural.hyperagent.plist"
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "Stopped and removed launchd service"
    fi
else
    if systemctl --user is-active hyperagent.service >/dev/null 2>&1; then
        systemctl --user stop hyperagent.service
    fi
    if systemctl --user is-enabled hyperagent.service >/dev/null 2>&1; then
        systemctl --user disable hyperagent.service
    fi
    rm -f "$HOME/.config/systemd/user/hyperagent.service"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "Stopped and removed systemd service"
fi

# Clean lock if stale
rm -f "$HYPERAGENT_DIR/.lock"

# Remove symlinked skills
for skill_dir in "$HYPERAGENT_DIR/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    target="$CLAUDE_DIR/skills/$skill_name"
    if [ -L "$target" ]; then
        rm "$target"
        echo "Removed skill: /$skill_name"
    fi
done

# Remove hooks from ~/.claude/settings.json
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    jq '
        .hooks //= {} |
        .hooks.SessionStart = [.hooks.SessionStart // [] | .[] | select(
            (.hooks // [] | all(.command | contains("hyperagent") | not))
        )] |
        .hooks.UserPromptSubmit = [.hooks.UserPromptSubmit // [] | .[] | select(
            (.hooks // [] | all(.command | contains("hyperagent") | not))
        )] |
        if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end |
        if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end |
        if (.hooks | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    echo "Removed hooks"
fi

# Remove config file
rm -f "$CLAUDE_DIR/hyperagent.json"

# Clean runtime files
rm -f "$HYPERAGENT_DIR/ledger"
rm -f "$HYPERAGENT_DIR/.last-check"
rm -f "$HYPERAGENT_DIR/.lock"
rm -f "$HYPERAGENT_DIR/.last-change"
rm -rf "$HYPERAGENT_DIR/.seen"

echo ""
echo "=== Hyperagent uninstalled ==="
echo "The hyperagent repo at $HYPERAGENT_DIR has not been deleted."
echo "Your ~/.claude/ configs and project configs have not been reverted."
echo "To fully remove: rm -rf $HYPERAGENT_DIR"
```

Mark executable: `chmod +x uninstall.sh`

---

## 12. Tools

The `tools/` directory in the hyperagent repo starts empty. The meta agent creates scripts here for its own use — transcript parsers, pattern matchers, scoring helpers, signal extractors, whatever it invents.

Each tool must have a header comment describing what it does and when to use it:

```bash
#!/usr/bin/env bash
# Tool: extract_corrections
# Purpose: Scan a transcript JSONL file for user correction patterns
# Usage: bash tools/extract_corrections.sh <transcript.jsonl>
# Output: One line per correction found, with context
```

The meta agent discovers tools by listing the directory and reading these headers at the start of each cycle. When creating a new tool, the meta agent ensures it is referenced from wherever it needs to be called — the meta agent's own definition, a skill, another tool, or any other appropriate location. The tool and the reference to it are created together.

For project-specific tools, the meta agent creates them at `<project>/.claude/hyperagent/tools/`. These are committed in the project repo by the watcher.

---

## 13. Rollback

### Global files (`~/.claude/`)

No git repo at `~/.claude/`. The changelog diff is the version history. To roll back:

1. Identify the changelog entry (via `/hyperagent-revert` skill or manual inspection).
2. Read the `< previous content` lines from the diff block.
3. Write the previous content back to the target file.
4. The watcher drives a new changelog entry documenting the revert.
5. The watcher commits the update in the hyperagent repo.

### Project files

Committed in the project git repo. Roll back with `git revert <hash>`, identified by `Hyperagent <hyperagent@local>` author or `[hyperagent]` prefix.

### Self (meta_agent.md, memory.md, tools/)

Committed in the hyperagent repo. Roll back with `git revert <hash>`.

---

## 14. Growth Management

The meta agent reads its own `memory.md` directly. The changelog is not passed to the meta agent during its main work phase — it's only involved during the watcher-driven changelog-writing phase, where the meta agent writes to it, not reads from it. The meta agent records summaries of its own recent changes in memory for regression detection.

The meta agent's instructions include a housekeeping heuristic for consolidating memory beyond 200 lines.

The `.last-change` file is overwritten each cycle (one line). The `.seen/` directory is cleaned of files older than 48 hours by the watcher.

---

## 15. Constraints

- `watcher.sh` and all hooks must work on Linux and macOS without modification. GNU/BSD `stat` detection is included.
- No runtime dependencies beyond bash, `claude`, `git`, and `jq`.
- The meta agent is invoked via `claude -p`. It inherits MCP server configuration from the user's setup.
- All git operations use `--author="Hyperagent <hyperagent@local>"` and `[hyperagent]` message prefix.
- The watcher sleeps 60 seconds between loops. Hook scripts have a 5-second timeout.
- `watcher.sh`, `hooks/`, `install.sh`, `uninstall.sh`, and `skills/` (the shipped skills) are fixed infrastructure. The meta agent must not modify them. Enforced by instruction only.
- Git commits and changelog entries are enforced architecturally by the watcher, not by the meta agent's instructions.
- Skills the meta agent creates for the user go in `~/.claude/skills/` or `<project>/.claude/skills/`. These hot-reload without session restart.
- Tools the meta agent creates for itself go in `tools/` (global) or `<project>/.claude/hyperagent/tools/` (project-specific).
- Notifications use Claude Code's native hook system. `SessionStart` and `UserPromptSubmit` hooks check a single `.last-change` file against per-session `.seen/<session_id>` files. Each session independently discovers changes at its own pace. No MCP server required.
- `jq` is required for parsing `claude -p --output-format json` output and reading `session_id` from hook input.
