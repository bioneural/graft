<h1 align="center">
  g r a f t
  <br>
  <sub>self-improving configuration for claude code</sub>
</h1>

Claude Code is configured by hand. You write a `CLAUDE.md`. You add rules, skills, and agents. You correct the same behavior across sessions and projects, and nothing in the system registers the pattern. The configuration is always a snapshot of what you remembered to encode — never a reflection of what you actually need.

Graft ends this.

It constructs a hyperagent: a self-improving system that observes your Claude Code sessions, identifies what works and what fails, and rewrites your configuration accordingly. It operates between sessions. It requires no input from you. It improves its own capacity to improve.

From recursion, coherence. From coherence, command.

---

## Install

One command. Requires `claude`, `gh`, `git`, `jq`.

```bash
bash <(curl -sL -H "Accept: application/vnd.github.raw" https://api.github.com/repos/bioneural/graft/contents/bootstrap.sh)
```

Or specify where to install (defaults to `~/hyperagent`):

```bash
bash <(curl -sL -H "Accept: application/vnd.github.raw" https://api.github.com/repos/bioneural/graft/contents/bootstrap.sh) ~/repos/hyperagent
```

This downloads the specification, delivers it to Claude Code, and Claude Code constructs a private `hyperagent` repo under your GitHub account. The install script configures hooks and starts the watcher as a system service. Restart Claude Code once. The system is operational.

---

## Operation

You work. The hyperagent observes.

When a session goes idle for five minutes, the watcher triggers the meta agent. It reads the transcript. It scans recent transcripts for cross-session patterns. It decides whether intervention is warranted.

Most cycles produce no change. Not every session contains a lesson.

Examples of what a change might look like:

- Adding a rule to `~/.claude/CLAUDE.md` because a correction appeared three times across projects.
- Placing a scoped rule in `<project>/.claude/rules/` because Claude mishandles that repo's test framework.
- Creating a skill to automate a manual pattern.
- Rewriting the meta agent's own instructions, because it found a better method of analysis.

The next message you send, or the next session you start, a single line appears: what changed and whether `/hyperagent-reload` is needed. Each session tracks what it has already seen. No repetition. No interruption.

If a change degrades performance, the meta agent detects the regression on subsequent cycles and reverts it. You may also invoke `/hyperagent-revert` at any time. Every modification is recorded with a full diff in the changelog. Nothing is irreversible.

---

## Signal

The meta agent begins with zero knowledge of you. No assumptions about your tools, preferences, or workflow.

It starts with one signal source: session transcripts. JSONL files written to disk by Claude Code in real time. Every message, tool call, and response.

From transcripts, it identifies:

- Corrections. You overrode Claude's output.
- Repetition. The same instruction appears across sessions.
- Friction. Multiple rephrasings before comprehension.
- Missing context. Work began without sufficient information.
- Success. Patterns that produced clean outcomes.

Additional signal sources are discovered through observation. A PR comment pasted into a session reveals that PR feedback is a signal. If a GitHub MCP server is connected, the meta agent begins querying it directly. If not, it records the discovery and works with what the transcripts contain.

No one tells it where to look. It determines this itself.

---

## Placement

Learnings are placed at the correct scope.

| Scope | Location | Loaded |
|---|---|---|
| Universal | `~/.claude/CLAUDE.md` | Every session |
| Project | `<project>/CLAUDE.md` | That project's sessions |
| Path-scoped | `<project>/.claude/rules/` | When matching files are touched |
| Subdirectory | `<project>/<subdir>/CLAUDE.md` | When working in that subtree |
| Skills | `~/.claude/skills/` or project-level | On demand or auto-invoked |
| Self | `meta_agent.md` | Next cycle |

A pattern observed across three projects is universal. A pattern confined to one repo is project-level. A pattern confined to `src/api/` receives a path-scoped rule. The meta agent determines scope through observation.

---

## Architecture

Three components. No MCP servers. No Node.js. No Python.

**Watcher.** A bash daemon. Monitors `~/.claude/projects/` for idle transcripts. Invokes the meta agent. Drives the changelog entry by resuming the meta agent's session after its work completes. Commits all changes. Signals active sessions. Runs as a system service — launchd on macOS, systemd on Linux.

**Meta agent.** A markdown file passed to `claude -p`. Reads transcripts. Analyzes patterns. Edits configuration. Edits itself. The self-referential property: the mechanism that generates improvements is subject to improvement.

**Hooks.** Two bash scripts registered in `~/.claude/settings.json`. One fires at session start. One fires on each message. They check whether the watcher has committed changes since the session last looked. Each session maintains independent state. No races between concurrent sessions.

---

## Rollback

Every change is recorded in the changelog with a full diff. The changelog is written by the watcher, not the meta agent. The watcher resumes the meta agent's session after its work completes and instructs it to write the entry. The meta agent retains its full reasoning context. The entry is substantive. But the meta agent never considers changelog bookkeeping. The watcher enforces it architecturally.

For global files: the changelog is the version history. Rollback reads the previous content from the diff and writes it back.

For project files: changes are committed with author `Hyperagent <hyperagent@local>` and prefix `[hyperagent]`. Rollback is `git revert`.

Three skills are provided:

- `/hyperagent-reload` — restart Claude Code to apply configuration changes.
- `/hyperagent-changelog` — display recent modifications.
- `/hyperagent-revert` — roll back a specific change.
- `/hyperagent-status` — check whether the watcher is running and show recent activity.

---

## Persistence

The hyperagent repo contains the full state: evolved meta agent definition, accumulated memory, changelog, tools. Push to your remote. Clone on another machine.

```bash
gh repo clone <your-username>/hyperagent ~/hyperagent
~/hyperagent/install.sh
```

The system resumes with everything it has learned.

---

## Constraints

This system does not modify Claude Code itself. It writes configuration files.

It does not operate in the cloud. Everything runs locally.

It is not a replacement for deliberate configuration. It is a system that produces deliberate configuration — continuously, from observation.

It makes mistakes. That is why every change is diffed, logged, and reversible.

---

## Dependencies

```
bash
claude
gh
git
jq
```

Nothing else.

---

## Origin

The [Hyperagents paper](https://arxiv.org/abs/2603.19461) (Zhang et al., 2026) introduced self-referential agents that unify task execution and self-modification in a single editable program. The paper demonstrated that meta-level improvements — improvements to the improvement process — transfer across domains and compound across runs.

That work ran on benchmarks. This runs on your work.

---

## Contents

| File | Function |
|---|---|
| `bootstrap.sh` | Downloads the specification. Invokes Claude Code. Constructs your private hyperagent repo. |
| `hyperagent-spec.md` | Complete implementation specification. Every file, mechanism, and constraint. |
| `implement-hyperagent.md` | Execution instructions for Claude Code. |
| `README.md` | This document. |
