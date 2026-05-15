# Contributing

Contributions are welcome. This project is a set of Claude Code skill files — structured markdown prompts that instruct an AI agent to perform layered security reviews. The best contributions are ones that make the agent smarter, reduce false positives, or extend coverage to new ecosystems.

---

## What We're Looking For

### High value
- **New scanning tools** — if you know a well-maintained tool that covers a gap in the current stack, open an issue describing what it catches that existing tools miss
- **New semantic analysis categories** — additions to the Phase 2 checklists in `security-review.md` or `arch-review.md` that represent things no static tool can catch
- **False positive refinements** — improvements to the Hard Exclusions or Precedents sections based on real-world noise you've observed
- **New language/ecosystem support** — a new skill file (e.g., `python-review.md`, `go-review.md`) following the same two-layer pattern
- **CI workflow improvements** — better GitHub Actions integration, support for GitLab CI or other platforms
- **Real-world test cases** — example codebases or diffs that demonstrate a finding the current skills catch (or miss)

### Not a good fit
- Changes that make the agent replicate what a tool already does well (pattern-matching, known CVE lookup, etc.)
- Adding tools without explaining what gap they fill that existing tools don't cover
- Increasing verbosity or adding categories that produce more noise rather than higher signal

---

## Project Structure

```
.claude/
  commands/
    security-review.md   # /security-review — code-level: npm/JS, supply chain, licenses
    arch-review.md       # /arch-review     — infrastructure: IaC, containers, CI/CD
    full-review.md       # /full-review     — orchestrator: runs both in parallel
.github/
  workflows/
    security-scan.yml    # CI workflow — runs all tools on PRs, posts results as comment
install.sh               # Installer for all 3 deployment scenarios
README.md
CONTRIBUTING.md
LICENSE
```

The orchestrator (`full-review.md`) reads the other two skill files at runtime from `.claude/commands/` — keep all three in the same directory. The repo structure mirrors the installation target exactly, so `install.sh` is a straight copy.

---

## Skill File Conventions

All skill files follow the same pattern. When adding a new one or modifying an existing one, maintain these conventions:

**Frontmatter**
- `allowed-tools` must be explicit — list only the bash commands the agent actually needs
- `description` is shown in the Claude Code command palette — keep it under 100 characters

**Phase 0 — Automated Tools**
- Each tool entry must state what OWASP categories it covers
- Must include a graceful fallback: `[NOT RUN — not installed]` if the tool is absent
- Tools must produce JSON output for consistent machine-readable results

**Phase 2 — Semantic Analysis**
- Each category must be something a static tool structurally cannot catch
- Sub-questions should be concrete and answerable by reading code or config — not open-ended
- If you can write a Semgrep rule for it, it belongs in Phase 0, not Phase 2

**Hard Exclusions**
- Each exclusion must be justified — if it's excluded because a tool covers it, name the tool
- Numbered list, no duplicates

**Confidence and Output**
- Minimum threshold is 8/10 — do not lower this
- Output format fields are required; do not add optional fields without updating all skill files

---

## Adding a New Tool

1. Open an issue first — describe what the tool catches, whether it produces JSON output, whether it's free or commercial, and what existing tool (if any) it overlaps with
2. Add it to the relevant Phase 0 section with the exact command, a graceful fallback, and OWASP coverage notes
3. Add the corresponding Hard Exclusion (so the agent doesn't duplicate what the tool finds)
4. Add it to the CI workflow in README.md
5. Add it to the tools table in README.md

---

## Adding a New Ecosystem Skill

If you want to add support for a new language or ecosystem (Python, Go, Ruby, Java, etc.):

1. Copy the structure of `security-review.md`
2. Replace the npm/JS-specific tools in Phase 0 with the ecosystem's equivalents
3. Keep Phase 2 — the semantic categories (business logic, authz, second-order injection, etc.) apply universally
4. Adjust Hard Exclusions for ecosystem-specific precedents (e.g., memory safety in Rust/Go changes what's reportable)
5. Update `full-review.md` to optionally spawn the new skill if the relevant file types are detected in the diff
6. Document the new skill and its tools in README.md

---

## Submitting a Pull Request

1. Fork the repository and create a branch from `main`
2. Make your changes — keep each PR focused on one concern
3. Test your skill changes against a real repository with known issues if possible
4. Update README.md if you've added tools, skills, or changed the workflow
5. Open the PR with a description that explains what the change improves and why

There are no automated tests for prompt files — reviewers will assess whether Phase 2 categories are genuinely beyond tool coverage, whether new tools are justified, and whether Hard Exclusions are consistent.

By submitting a contribution you agree that your work will be licensed under the GNU Affero General Public License v3.0 (AGPLv3), the same license as this project.

---

## Questions and Discussion

Open a GitHub Issue for anything you're unsure about before investing time in a PR. Tag it with `question` and describe what you're trying to improve.
