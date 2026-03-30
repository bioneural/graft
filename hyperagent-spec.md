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
│   └── hyperagent-status/SKILL.md  # /hyperagent-status skill. §3.
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
```

Everything else is tracked, including `tools/`, `meta_agent.md`, `memory.md`, `changelog.md`, `hooks/`, and `skills/`.

---

## 3. Skills

Skills are the modern Claude Code extensibility system. They live in `.claude/skills/<n>/SKILL.md`, support YAML frontmatter, hot-reload mid-session (no restart required for new or modified skills), and can be auto-invoked or manually invoked via `/name`.

The hyperagent ships four skills. `install.sh` symlinks them into `~/.claude/skills/` so they're available globally. All skill names are prefixed with `hyperagent-` to avoid collisions with other tools.

### `skills/hyperagent-reload/SKILL.md`

```markdown
---
name: hyperagent-reload
description: Reload Claude Code to pick up CLAUDE.md changes. Use when the hyperagent notifies you of configuration updates.
disable-model-invocation: true
---
# Reload Claude Code
!`kill -HUP $PPID`
```

### `skills/hyperagent-changelog/SKILL.md`

```markdown
---
name: hyperagent-changelog
description: Show recent hyperagent changes. Use when user asks about what the hyperagent has changed, or after receiving a hyperagent notification.
disable-model-invocation: true
---
Read the hyperagent changelog file and display the 10 most recent entries. Each entry starts with a `## ` heading containing a timestamp.

Changelog location: HYPERAGENT_DIR_PLACEHOLDER/changelog.md

If the user provides arguments: $ARGUMENTS — use them to filter (e.g. "this week", "last 5", "show all", a specific date).
```

`install.sh` replaces `HYPERAGENT_DIR_PLACEHOLDER` with the actual absolute path when symlinking.

### `skills/hyperagent-revert/SKILL.md`

```markdown
---
name: hyperagent-revert
description: Roll back a hyperagent change. Use when user says "undo", "roll back", or "revert" in reference to a hyperagent change, or when user is unhappy with a recent Claude Code behavior change.
disable-model-invocation: true
---
# Revert a Hyperagent Change

1. Read the hyperagent changelog at HYPERAGENT_DIR_PLACEHOLDER/changelog.md.
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
8. Append a revert entry to HYPERAGENT_DIR_PLACEHOLDER/changelog.md documenting what was reverted and why.
9. Tell the user to `/hyperagent-reload` if a CLAUDE.md file was affected.
```

`install.sh` replaces `HYPERAGENT_DIR_PLACEHOLDER` with the actual absolute path.

### `skills/hyperagent-status/SKILL.md`

```markdown
---
name: hyperagent-status
description: Check whether the hyperagent watcher is running and show recent activity. Use when user asks about hyperagent health or status.
disable-model-invocation: true
---
# Hyperagent Status

Check the following and report to the user:

1. **Watcher process**: Check if the watcher is running.
   - macOS: `launchctl list com.bioneural.hyperagent 2>/dev/null`
   - Linux: `systemctl --user status hyperagent.service 2>/dev/null`
   - Fallback: `pgrep -f "watcher.sh" >/dev/null 2>&1`

2. **Last heartbeat**: Read `HYPERAGENT_DIR_PLACEHOLDER/.heartbeat`. It contains an epoch timestamp updated every watcher loop iteration (every 60 seconds). Calculate how long ago the last heartbeat was. If the file is missing or the heartbeat is older than 5 minutes, the watcher is not running normally.

3. **Last change**: Read `HYPERAGENT_DIR_PLACEHOLDER/.last-change`. Show when the last change was made and what it was.

4. **Recent changelog**: Show the 3 most recent entries from `HYPERAGENT_DIR_PLACEHOLDER/changelog.md` (timestamps and TL;DR lines only).

5. **Watcher log**: Show the last 20 lines of `/tmp/hyperagent.log` if it exists.

Format the output clearly. If the watcher is not running, tell the user how to restart it:
- macOS: `launchctl kickstart -k gui/$(id -u)/com.bioneural.hyperagent`
- Linux: `systemctl --user restart hyperagent.service`
```

`install.sh` replaces `HYPERAGENT_DIR_PLACEHOLDER` with the actual absolute path.

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
5. Decide whether a new change is warranted. If no clear actionable pattern, record observations in memory and stop.
6. If a change is warranted, make it. See "Where to write" below.
7. Update $HYPERAGENT_DIR/memory.md with what you observed, what you changed (or chose not to change), your hypothesis, and what to look for next.
8. Write a summary to stdout. Use one of these prefixes so the watcher knows what happened:
   - `NOTIFY_RELOAD: <tl;dr>` — a CLAUDE.md or rules file was changed, user should /hyperagent-reload
   - `NOTIFY_SKILL: <tl;dr>` — a skill was created or modified, no reload needed (hot-reload)
   - `NOTIFY_INFO: <tl;dr>` — informational, no action needed from user
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

## Housekeeping

When memory.md exceeds 200 lines, consolidate: summarize entries older than 2 weeks into a compact section at the top, remove their raw detail. Keep recent entries intact. You may change this heuristic.

## Starting heuristics

Modify these if you learn something better.

- Prefer one focused change per cycle for clean attribution and rollback.
- Prefer small, targeted modifications over wholesale rewrites.
- Act on patterns seen 3+ times across sessions. Record patterns seen fewer times as hypotheses.
- Not every cycle needs to produce a change.
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
META_AGENT="$HYPERAGENT_DIR/meta_agent.md"

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

commit_hyperagent_repo() {
    local tl_dr="$1"
    cd "$HYPERAGENT_DIR"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -A
        git commit --author="Hyperagent <hyperagent@local>" \
            -m "[hyperagent] ${tl_dr:-auto-commit}" \
            2>/dev/null || true
    fi
}

commit_project_repo() {
    local project_path="$1"
    local tl_dr="$2"
    if [ -z "$project_path" ] || [ ! -d "$project_path/.git" ]; then
        return
    fi
    cd "$project_path"
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
            --max-turns 200 \
            --output-format json \
            --bare \
            2>/dev/null) || true

    # Cancel the watchdog if we finished in time
    kill "$watchdog_pid" 2>/dev/null || true

    # Extract session ID and notify line
    local session_id
    session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null || echo "")

    local result_text
    result_text=$(echo "$output" | jq -r '.result // empty' 2>/dev/null || echo "")

    local notify_line
    notify_line=$(echo "$result_text" | grep -E "^NOTIFY_(RELOAD|SKILL|INFO):" | head -1 || echo "")

    local tl_dr
    tl_dr=$(echo "$notify_line" | sed 's/^NOTIFY_[A-Z]*: //')

    local notify_type=""
    if echo "$notify_line" | grep -q "^NOTIFY_RELOAD:"; then
        notify_type="reload"
    elif echo "$notify_line" | grep -q "^NOTIFY_SKILL:"; then
        notify_type="skill"
    elif echo "$notify_line" | grep -q "^NOTIFY_INFO:"; then
        notify_type="info"
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
                --max-turns 5 \
                --bare \
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
}

# --- Main loop ---

while true; do
    # Write heartbeat so hooks and /hyperagent-status can detect a stalled watcher
    date +%s > "$HEARTBEAT"

    modified=$(find "$PROJECTS_DIR" -name "*.jsonl" -newer "$MARKER" -type f 2>/dev/null || true)
    touch "$MARKER"

    now=$(now_epoch)

    all_transcripts=$(
        echo "$modified"
        awk -F'\t' '{print $1}' "$LEDGER" 2>/dev/null
    )
    all_transcripts=$(echo "$all_transcripts" | sort -u | grep -v '^$' || true)

    for transcript in $all_transcripts; do
        [ -f "$transcript" ] || continue

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
        run_meta_agent "$transcript"
        release_lock

        set_ledger_entry "$transcript" "$current_mtime" "0"
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

1. After committing changes, the watcher writes `~/hyperagent/.last-change` containing: epoch timestamp, notification type (`reload`/`skill`/`info`), and TL;DR, tab-separated on one line.
2. Each hook receives `session_id` in its JSON input. It compares the `.last-change` timestamp against a per-session file at `~/hyperagent/.seen/<session_id>`. If the change is newer than what the session last saw (or the session has no `.seen` file), the hook injects a notification and updates the `.seen` file.
3. The watcher periodically cleans `.seen/` files older than 48 hours.

### `hooks/on-session-start.sh`

Fires on session startup, resume, clear, and compact.

```bash
#!/usr/bin/env bash
HYPERAGENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAST_CHANGE="$HYPERAGENT_DIR/.last-change"
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
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Run /hyperagent-reload to apply, /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "skill" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Already available (no reload needed). /hyperagent-changelog for details.\"}"
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
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Run /hyperagent-reload to apply, /hyperagent-changelog for details.\"}"
    elif [ "$CHANGE_TYPE" = "skill" ]; then
        echo "{\"additionalContext\": \"[Hyperagent] $CHANGE_TLDR. Already available (no reload needed). /hyperagent-changelog for details.\"}"
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

# --- Symlink skills into ~/.claude/skills/ ---

mkdir -p "$CLAUDE_DIR/skills"

for skill_dir in "$HYPERAGENT_DIR/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    target="$CLAUDE_DIR/skills/$skill_name"

    # Patch HYPERAGENT_DIR_PLACEHOLDER in SKILL.md
    if grep -q "HYPERAGENT_DIR_PLACEHOLDER" "$skill_dir/SKILL.md" 2>/dev/null; then
        sed "s|HYPERAGENT_DIR_PLACEHOLDER|$HYPERAGENT_DIR|g" "$skill_dir/SKILL.md" > "$skill_dir/SKILL.md.patched"
        mv "$skill_dir/SKILL.md.patched" "$skill_dir/SKILL.md"
    fi

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
    <key>StandardOutPath</key>
    <string>/tmp/hyperagent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/hyperagent.log</string>
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
