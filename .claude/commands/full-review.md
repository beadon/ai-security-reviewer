---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Bash(gh api:*), Read, Glob, LS, Task, Write
description: Full security review — orchestrates parallel code-level and infrastructure security analysis, merges into a unified report
version: "{{VERSION}}"
---

> !`gh api repos/beadon/ai-security-reviewer/releases/latest --jq 'if .tag_name != "{{VERSION}}" and "{{VERSION}}" != "development" then "⚠️  Update available: " + .tag_name + " (installed: {{VERSION}})" else empty end' 2>/dev/null || true`

## Role

This skill is a **pure orchestrator**. It does not perform security analysis directly. It:

1. Collects the branch context once
2. Reads both skill files to get their full instructions
3. Launches the code-level review and the infrastructure review as **parallel sub-tasks**
4. Merges both reports into a single unified output

---

## Branch Context

GIT STATUS:
```
!`git status`
```

FILES MODIFIED:
```
!`git diff --name-only origin/HEAD...`
```

COMMITS:
```
!`git log --no-decorate origin/HEAD...`
```

FULL DIFF:
```
!`git diff --merge-base origin/HEAD`
```

---

## Execution

### Step 0 — Inspection Tool Permissions

Sub-task agents use `python3`, `sed`, `awk`, `jq`, `find`, `wc`, `sort`, `uniq`, `cut`, `tr`, `head`, `tail`, `cat`, `stat`, and `file` to inspect files during analysis. Without pre-approval in your global Claude settings, each command triggers a permission prompt mid-review.

1. Use the Read tool to check whether `~/.claude/settings.json` exists and contains `Bash(python3:*)` in `permissions.allow`.
2. If present: skip to Step 1.
3. If absent: tell the user — *"This review's sub-agents will run python3, sed, awk, jq, find, and similar read-only tools to inspect files. Without pre-approval you'll be prompted for each command individually. I can add them to your global Claude settings (`~/.claude/settings.json`) now — one approval here instead of many prompts during the review. This will not modify the repository being reviewed."* Ask whether to proceed.
4. If the user approves: write an updated `~/.claude/settings.json` that merges the following entries into `permissions.allow`, preserving all existing entries. If the file does not exist, create it. **Write to `~/.claude/settings.json` only — do not create or modify any file in the current working directory.**

   ```
   Bash(python3:*), Bash(python:*), Bash(sed:*), Bash(awk:*), Bash(jq:*),
   Bash(find:*), Bash(xargs:*), Bash(wc:*), Bash(sort:*), Bash(uniq:*),
   Bash(cut:*), Bash(tr:*), Bash(head:*), Bash(tail:*), Bash(cat:*),
   Bash(stat:*), Bash(file:*)
   ```

5. If the user declines: note that prompts will appear for individual commands and continue.

---

### Step 1 — Load Skill Files

Read both skill files. Try the project-level location first; fall back to the global location.

For the code-level skill, try in order:
1. `.claude/commands/security-review.md`
2. `~/.claude/commands/security-review.md`

For the infrastructure skill, try in order:
1. `.claude/commands/arch-review.md`
2. `~/.claude/commands/arch-review.md`

If a skill file cannot be found at either location, note it and proceed — the other sub-task will still run.

---

### Step 2 — Launch Parallel Sub-Tasks

Launch **both sub-tasks simultaneously**. Do not wait for one to finish before starting the other.

---

**Sub-task A — Code-Level Security Review**

The sub-task prompt must be fully self-contained. Construct it as follows:

```
You are executing a code-level security review. The branch context has already been collected by the orchestrator — do not re-run git commands.

BRANCH CONTEXT (provided by orchestrator):
[Insert the full output of the git status, files modified, commits, and full diff collected above]

SKILL INSTRUCTIONS:
[Insert the complete content of security-review.md, starting from the ## Role section, omitting the Branch Context section since it is already provided above]

Execute all phases as instructed. Return your complete findings as a markdown report.
```

---

**Sub-task B — Infrastructure Security Review**

The sub-task prompt must be fully self-contained. Construct it as follows:

```
You are executing an infrastructure and deployment security review. The branch context has already been collected by the orchestrator — do not re-run git commands.

BRANCH CONTEXT (provided by orchestrator):
[Insert the full output of the git status, files modified, commits, and full diff collected above]

SKILL INSTRUCTIONS:
[Insert the complete content of arch-review.md, starting from the ## Role section, omitting the Branch Context section since it is already provided above]

Execute all phases as instructed. Return your complete findings as a markdown report.
```

---

### Step 3 — Merge and Output Unified Report

Once both sub-tasks return their reports, combine them into the format below.

Do not summarise or paraphrase findings — include them verbatim from each sub-task. Only reformat section headers to fit the unified structure.

---

## Unified Report Format

```markdown
# Security Review — [repo name] @ [branch name]

## Summary

| Layer | Semantic Findings | Tool Findings |
|-------|-------------------|---------------|
| Code-level | N | N |
| Infrastructure | N | N |
| **Total** | **N** | **N** |

---

## Part 1 — Code-Level Findings

> Powered by: npm audit · Semgrep · gitleaks · njsscan · license-checker · socket.dev (if configured)

### Section A — Semantic Findings (AI-Detected)
[Code-level Section A findings from Sub-task A, verbatim]

### Section B — Tool Findings (Triaged and Enriched)
[Code-level Section B findings from Sub-task A, verbatim]

---

## Part 2 — Infrastructure Findings

> Powered by: Checkov · hadolint · Trivy config · tflint · ansible-lint

### Section C — Semantic Findings (AI-Detected)
[Infrastructure Section A findings from Sub-task B, verbatim]

### Section D — Tool Findings (Triaged and Enriched)
[Infrastructure Section B findings from Sub-task B, verbatim]
```

If a part has no findings, output:
`No high-confidence findings in this layer for this changeset.`

Output the unified report and nothing else.
