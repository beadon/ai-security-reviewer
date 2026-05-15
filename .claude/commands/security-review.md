---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Bash(gh api:*), Bash(npm audit:*), Bash(semgrep:*), Bash(gitleaks:*), Bash(njsscan:*), Bash(retire:*), Bash(socket:*), Bash(npx license-checker-rseidelsohn:*), Bash(npx @onebeyond/license-checker:*), Bash(npx htmlhint:*), Bash(npx skills:*), Bash(scancode:*), Bash(printenv:*), Bash(which:*), Read, Glob, Grep, LS, Task, Write
description: Security review for npm/JS — automated tool scans followed by AI semantic analysis of what tools cannot catch
version: "{{VERSION}}"
---

> !`gh api repos/beadon/ai-security-reviewer/releases/latest --jq 'if .tag_name != "{{VERSION}}" and "{{VERSION}}" != "development" then "⚠️  Update available: " + .tag_name + " (installed: {{VERSION}})" else empty end' 2>/dev/null`

## Step 0 — Inspection Tool Permissions

Sub-task agents use `python3`, `sed`, `awk`, `jq`, `find`, `wc`, `sort`, `uniq`, `cut`, `tr`, `head`, `tail`, `cat`, `stat`, and `file` to inspect files during analysis. Without pre-approval in your global Claude settings, each command triggers a permission prompt mid-review.

1. Use the Read tool to check whether `~/.claude/settings.json` exists and contains `Bash(python3:*)` in `permissions.allow`.
2. If present: skip to **Role**.
3. If absent: tell the user — *"This review's analysis agents will run python3, sed, awk, jq, find, and similar read-only tools to inspect files. Without pre-approval you'll be prompted for each command individually. I can add them to your global Claude settings (`~/.claude/settings.json`) now — one approval here instead of many prompts during the review. This will not modify the repository being reviewed."* Ask whether to proceed.
4. If the user approves: write an updated `~/.claude/settings.json` that merges the following entries into `permissions.allow`, preserving all existing entries. If the file does not exist, create it. **Write to `~/.claude/settings.json` only — do not create or modify any file in the current working directory.**

   ```
   Bash(python3:*), Bash(python:*), Bash(sed:*), Bash(awk:*), Bash(jq:*),
   Bash(find:*), Bash(xargs:*), Bash(wc:*), Bash(sort:*), Bash(uniq:*),
   Bash(cut:*), Bash(tr:*), Bash(head:*), Bash(tail:*), Bash(cat:*),
   Bash(stat:*), Bash(file:*)
   ```

5. If the user declines: note that prompts will appear for individual commands and continue.

---

## Role

This is a **two-layer security review pipeline** for npm/JavaScript codebases.

**Layer 1 — Tools (you run these in Phase 0):** Pattern-matching, known CVEs, hardcoded secrets, and injection anti-patterns. These are handled by purpose-built scanners that are faster, more precise, and more exhaustive than any LLM at this class of problem.

**Layer 2 — Semantic analysis (your actual job):** Triage tool findings with business context, then find what no pattern-matcher can catch: business logic flaws, authorization model errors, second-order vulnerabilities, chained exploits, and cross-boundary trust violations.

**Do NOT re-derive what the tools already report.** If a tool flagged an injection sink on line 42, your job is to assess exploitability in this codebase — not to re-explain the vulnerability class.

**Tool constraints:** Only use the tools listed in `allowed-tools`. Do not write files except `.claude/settings.json` during Step 0. Do not run arbitrary bash commands beyond those listed.

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

DIFF CONTENT:
```
!`git diff --merge-base origin/HEAD`
```

---

## Phase 0 — Automated Tool Scans

Run each command below using your bash tool. Capture all output verbatim. If a tool is not installed, record `[NOT RUN — not installed]` for that tool and continue. Do not abort if tools are missing.

### npm audit
```
npm audit --json 2>/dev/null; true
```
Covers: known CVEs in the dependency tree (OWASP A06).

### Semgrep
```
semgrep scan --config p/javascript --config p/nodejs --config p/secrets --json . 2>/dev/null
```
Covers: injection patterns, XSS sinks, prototype pollution, unsafe deserialization, hardcoded credentials (OWASP A02, A03, A08). Note: `p/html` is not available in the Semgrep registry — HTML-specific checks are handled by HTMLHint below.

### gitleaks
```
gitleaks detect --report-format json --exit-code 0 2>/dev/null
```
Covers: secrets and tokens committed to the repository (OWASP A02).

### njsscan
```
njsscan --json . 2>/dev/null
```
Covers: Node.js/Express misconfigurations, missing security middleware (OWASP A05, A07).

### Retire.js *(optional — CDN/inline script dependency CVEs)*
```
retire --outputformat json --path . 2>/dev/null; true
```
Covers: known CVEs in CDN-loaded or inline script dependencies that `npm audit` cannot see — e.g., a library loaded via `<script src>` tag with a pinned version that has a known exploit (OWASP A06). Particularly relevant for HTML apps that load libraries outside npm.

### HTMLHint *(optional — HTML security attributes)*
```
npx htmlhint --format json '**/*.html' 2>/dev/null; true
```
Covers: missing `Content-Security-Policy` meta tags, inline event handlers (`onclick`, `onload`), missing `rel="noopener noreferrer"` on `target="_blank"` links, form fields missing `autocomplete="off"` for sensitive inputs (OWASP A05).

### License Checker *(optional — free)*
```
npx license-checker-rseidelsohn --json --excludePrivatePackages 2>/dev/null
```
Covers: copyleft licenses (GPL, AGPL, LGPL) and unknown licenses in the dependency tree that could create legal or supply chain risk. If the above is not available, try `npx @onebeyond/license-checker --json 2>/dev/null`.

### Copyright and License Notice Scanner *(optional — scancode-toolkit)*

First check if scancode is available:
```
which scancode 2>/dev/null
```
If available, run it. In diff mode, scope to changed files to keep scan time reasonable; in codebase mode (empty diff), scan the full directory:
```
DIFF_FILES=$(git diff --name-only origin/HEAD... 2>/dev/null | tr '\n' ' ')
if [ -n "$DIFF_FILES" ]; then
  scancode --license --copyright --json-pp /tmp/scancode.json $DIFF_FILES 2>/dev/null
else
  scancode --license --copyright --json-pp /tmp/scancode.json . 2>/dev/null
fi
```
If scancode is not installed, record `[NOT RUN — scancode not installed]` and continue.

Covers: copyright notices embedded in source file headers, license identifiers in individual files, and detection of code snippets that originate from open source projects — catching GPL/AGPL-contaminated code copied directly into the codebase rather than imported as a dependency. This is what license-checker cannot do: license-checker reads `package.json` metadata; scancode reads the actual source files (OWASP A06, legal/IP risk).

### Socket.dev *(optional — requires `SOCKET_API_KEY`)*

Check whether the API key is configured before running:
```
printenv SOCKET_API_KEY
```
If the key is present, run:
```
socket scan create --json . 2>/dev/null
```
If `SOCKET_API_KEY` is not set, record `[NOT RUN — SOCKET_API_KEY not configured]` and continue.

Covers: supply chain attacks — malicious install scripts, typosquatted packages, dependency confusion, packages with new or unknown maintainers, protestware, packages exfiltrating data at install time (OWASP A06, supply chain).

### Supabase Security Scan *(conditional — only when Supabase is detected)*

First, detect Supabase using the Grep tool — search for `@supabase/supabase-js` in `package.json`, or `createClient` / `SUPABASE_URL` / `SUPABASE_ANON_KEY` anywhere in the project. If no match is found, skip this section entirely.

If Supabase is detected, attempt to install the official Supabase agent skills for additional Postgres guidance (fails gracefully if unavailable):
```
npx skills add supabase/agent-skills 2>/dev/null; true
```

Then run these targeted checks:

**Service role key exposure** (critical — this key bypasses RLS entirely):
Search with the Grep tool for `service_role` or `SERVICE_ROLE_KEY` in any non-`.env` file, especially `.js`, `.ts`, `.html`, or any file that could be loaded in a browser.

**Table access inventory** — list every Supabase table the code reads or writes:
Search with the Grep tool for `.from('` or `.from("` across the codebase. Record each unique table name — these are the tables that must have RLS policies.

**RLS policy coverage** — for each table identified above, search the Grep tool for the table name alongside `ENABLE ROW LEVEL SECURITY`, `CREATE POLICY`, or `FORCE ROW LEVEL SECURITY` in any `.sql`, migration, or schema file. Flag tables with no policy evidence.

**SECURITY DEFINER functions** — search with the Grep tool for `SECURITY DEFINER` in SQL or migration files. For each match, note the function name — these bypass the caller's RLS context.

Covers: Supabase-specific auth bypass patterns, tenant isolation failures, accidental RLS bypass, and service key exposure (OWASP A01, A02, A04).

---

## Phase 1 — Codebase Context

Use file-reading and search tools to understand the project before analyzing the diff. Establish:

- **Trust model:** What data enters the system from untrusted sources (HTTP bodies, query params, headers, file uploads, websockets, IPC)? What is trusted (env vars, internal service calls, database reads)?
- **Auth/authz layer:** What middleware or patterns enforce authentication and authorization? (passport, express-jwt, custom middleware chains, RBAC models)
- **Security middleware:** Is helmet, cors, csurf, express-rate-limit, or equivalent present? How is it configured?
- **Data flow:** How does user input travel from HTTP handlers to persistence (DB queries, file writes, cache) and back out?
- **Validation layer:** What sanitization and validation libraries are in use (express-validator, joi, zod, yup)? Where are they applied?
- **HTML surface area:** If the project contains `.html` files with embedded `<script>` blocks or inline event handlers, treat all inline JavaScript as first-class JS surface area subject to the same analysis as `.js` files. Note whether the app is a serverless SPA (no backend — Supabase, Firebase, or similar direct DB access) vs. a server-backed app, as this changes the scope of client-side auth analysis.
- **Supabase model:** If Supabase is detected, establish: which tables exist and which have confirmed RLS policies; whether the app uses the anon key or the service role key; whether RPC functions are called and whether any may be `SECURITY DEFINER`; whether the app is truly serverless (RLS is the only enforcement layer) or has a backend that can double-check access.

---

## Phase 2 — Semantic Analysis (what tools cannot catch)

Work through each category below against the diff. These require understanding intent, cross-file data flow, and the relationship between code and business rules — things no pattern-matcher can do.

### 2.1 · Business Logic Flaws
- Does the new code actually enforce the business rules the PR description claims?
- Can a user perform operations out of intended sequence to gain an advantage (confirm before paying, skip a verification step, reuse a one-time token)?
- Are there assumptions about state or ordering that an attacker could violate?
- Can legitimate operations be abused in combination or at scale (bulk APIs, undo flows, retry logic, concurrent requests)?

### 2.2 · Authorization Model Correctness
- Is the authorization check performed **before** the sensitive operation — not after fetching the data, not as a post-condition?
- Is the check on the right principal — the authenticated user from the session, not a user-supplied ID in the request body?
- Are there conditional branches (feature flags, role checks, content-type switches) that skip authorization under specific inputs or states?
- Does the PR introduce new resources, operations, or roles without corresponding authorization enforcement anywhere in the call chain?

### 2.3 · Second-Order Injection
- Is any data stored by this PR later retrieved and used in a dangerous context (SQL query, shell command, HTML template, `eval`) elsewhere in the codebase?
- Does sanitization happen only at input time, leaving stored values dangerous when consumed later?
- Search the codebase for where newly stored fields are read and used downstream.

### 2.4 · Cross-File Trust Boundary Violations
- Does user-controlled data cross a trust boundary without validation at that boundary?
- Does this PR change implicit trust assumptions between modules — for example, an internal helper that is now called from a public HTTP handler, or a service that now accepts external input without re-validating it?

### 2.5 · Chained Vulnerabilities
- Does this PR introduce a partial weakness that, composed with an existing weakness in the codebase, creates a complete exploit chain?
- Can two low-privilege operations be sequenced or combined to achieve a high-privilege outcome?

### 2.6 · Race Conditions with Business Impact (TOCTOU)
- Are there check-then-act patterns on security-sensitive operations: payments, role changes, quota enforcement, rate limits, inventory decrement?
- Is the window between the check and the act realistically exploitable under concurrent load in a Node.js process (async/await gaps, DB transaction boundaries, missing locks)?

### 2.7 · Semantic SSRF
- Is an outbound URL assembled across multiple steps or files where user input influences the host, protocol, or port (not just the path)?
- Does URL construction logic assume the hostname is safe without an explicit allowlist?

### 2.8 · Token, Session, and JWT Logic
- Does token validation enforce all security-relevant claims: `exp`, `aud`, `iss`, `sub`, `scope`?
- Is there a code path that accepts or partially trusts a token without the full validation chain?
- Can a token issued for one resource or audience be replayed in a different context?

### 2.9 · Supabase / Direct Database Security *(skip if Supabase not detected)*

- **Service role key in client code:** Is `SUPABASE_SERVICE_ROLE_KEY` or any `service_role` key referenced in code that runs in the browser, is bundled into a static asset, or is committed to the repository? The service role key bypasses RLS entirely — any client-side exposure is a complete auth bypass regardless of policy configuration.
- **RLS coverage:** For every table accessed via `.from('tablename')`, is there evidence of RLS policies in migration or schema files? A table without RLS that holds user data allows any authenticated (or even anonymous) user to read or write all rows.
- **`auth.uid()` vs. application-supplied IDs in policies:** Do RLS policies use `auth.uid()` (database-enforced, unforgeable) or a value passed in from application code (e.g., `current_setting('app.current_user_id')` set by the client)? Application-set context variables are spoofable if the client can call `SET` directly.
- **`FORCE ROW LEVEL SECURITY` absent:** Without `FORCE ROW LEVEL SECURITY`, the table owner role bypasses all policies. Check whether migration files pair `ENABLE ROW LEVEL SECURITY` with `FORCE ROW LEVEL SECURITY`.
- **Anon key scope:** What mutating operations (INSERT, UPDATE, DELETE) does the code perform using the anon/public key? Write operations via the anon key without restrictive RLS policies are accessible to any unauthenticated user.
- **SECURITY DEFINER functions called with user input:** RPC calls (`.rpc('function_name', args)`) where the target function is `SECURITY DEFINER` run with the definer's permissions and bypass the caller's RLS context. If user-controlled values are passed as arguments, assess whether the function enforces its own access control.
- **Migration safety:** Do any migration files use `ADD COLUMN NOT NULL` without a default, `DROP TABLE`, or `CREATE INDEX` without `CONCURRENTLY`? These acquire table-level locks that stall production traffic.

---

## Phase 3 — Tool Output Triage

Review the captured output from Phase 0. For each tool finding:

1. **Classify:** TRUE_POSITIVE or FALSE_POSITIVE, given the codebase context from Phase 1.
2. **Enrich true positives:** What is the actual exploitability and business impact in *this* application — not the generic tool description?
3. **Identify patterns:** Does a single finding indicate a wider pattern across the codebase that should be flagged separately?
4. **Discard false positives:** Note why briefly (e.g., "Semgrep flagged `eval` in a test fixture — excluded per rule 7") and move on.

---

## Output Format

Produce a single markdown report with two sections. Omit a section entirely if it has no qualifying findings.

### Section A — Semantic Findings (AI-Detected)

Findings from Phase 2 that the automated tools did not and could not report.

```
# A[N]: [Short Title] — `path/to/file:line`

* Severity: High | Medium | Low
* OWASP: A0X – [Category Name]
* Confidence: X/10
* Description: [What the vulnerability is and exactly where it appears]
* Exploit Scenario: [Concrete attacker steps → resulting impact in this application]
* Recommendation: [Specific fix; reference existing patterns in this codebase where possible]
```

### Section B — Tool Findings (Triaged and Enriched)

Confirmed true positives from Phase 3. Do not only copy tool output verbatim — add business context.

```
# B[N]: [Short Title] — `path/to/file:line`

* Severity: High | Medium | Low
* OWASP: A0X – [Category Name]
* Source: npm audit | Semgrep | gitleaks | njsscan | retire.js | htmlhint | supabase-skills | license-checker | scancode | socket.dev
* Business Impact: [Why this matters specifically in this application, not the generic risk class]
* Recommendation: [Specific fix]
```

If no findings survive filtering in either section: output `No high-confidence security vulnerabilities found in this changeset.`

---

## Severity and Confidence

| Severity | Criteria |
|----------|----------|
| **High** | Directly exploitable: RCE, auth bypass, data breach, privilege escalation |
| **Medium** | Requires specific conditions but significant impact when met |
| **Low** | Defense-in-depth — exposure without immediate exploitability |

| Confidence | Meaning |
|------------|---------|
| 9–10 | Certain exploit path; attack is concrete and impact is clear |
| 7–8  | Clear vulnerability with a known exploitation method |
| 4–6  | Probable vulnerability; requires specific conditions to trigger |
| 2–3  | Weak signal — worth noting but unconfirmed |
| < 2  | Do NOT report |

**Minimum threshold to report: 2/10**

---

## Hard Exclusions

The following are either covered by the Phase 0 tools or are explicitly out of scope. Do NOT report:

1. Known CVE or vulnerable dependency findings — `npm audit` covers this.
2. Hardcoded secrets, API keys, or tokens — `gitleaks` covers this.
3. Missing security middleware (helmet, CORS headers, CSRF protection) — `njsscan` covers this.
4. Denial of Service or resource exhaustion attacks.
5. Rate limiting concerns.
6. Memory consumption or CPU exhaustion.
7. Findings exclusively in unit test or test fixture files.
8. Log spoofing — unsanitized input in logs is not a vulnerability unless it exposes secrets or PII.
9. SSRF where the attacker controls only the **path** — must control host or protocol to be reportable.
10. User-controlled content in AI system prompts.
11. Regex injection or ReDoS.
12. Security findings in documentation files (`.md`, `.txt`, `.rst`).
13. Absence of audit logs.
14. Missing authorization in client-side JS/TS — the server is responsible. **Exception:** if the application has no backend server (pure static SPA with direct Supabase, Firebase, or similar client-side DB access), client-side auth logic IS in scope because there is no server-side enforcement fallback.
15. XSS in React or Angular unless `dangerouslySetInnerHTML`, `bypassSecurityTrustHtml`, or equivalent unsafe APIs are explicitly used.
16. Theoretical race conditions — only report TOCTOU with a realistically exploitable concurrent window.
17. Vulnerabilities in Jupyter notebooks without a concrete, triggerable attack path.
18. Command injection in shell scripts unless untrusted user input concretely reaches the vulnerable call.

### Precedents
- UUIDs are unguessable — do not flag as predictable identifiers.
- Environment variables and CLI flags are trusted — attacks requiring env var control are invalid.
- Logging URLs is assumed safe; logging secrets, passwords, or PII is a vulnerability.
- React and Angular escape output by default — only flag when unsafe rendering APIs are explicitly used.

---

## Execution Instructions

**Step 1 — Tool Scans and Context (sequential, must complete before Step 2)**
Run all Phase 0 tool scans using your bash tool — including the optional license-checker and socket.dev scans if available. Then complete Phase 1 codebase context research using file-reading tools. Record all output before proceeding.

**Codebase Mode (check first, before the scope gate)**

If `git diff --merge-base origin/HEAD` returned no output (clean working tree, or reviewing the default branch directly with no unreviewed changes):

- **Do not apply the scope gate below.**
- In Phase 2, instead of analyzing a diff, identify the **top 10 most security-relevant files** in the codebase using these heuristics (in priority order):
  1. Files containing auth, login, session, token, password, or permission logic
  2. Files with DB writes — Supabase, Firebase, ORM, or raw SQL calls that mutate data
  3. Files handling user input: form submissions, fetch/XHR handlers, file uploads
  4. Files using `innerHTML`, `eval`, `Function()`, `document.write`, or `dangerouslySetInnerHTML`
  5. API route or handler entry points
- Analyze those files in their entirety using all 8 Phase 2 categories, not against a diff.
- Phase 0 tool scans still run against the full directory — their output is unchanged.

---

**Scope Gate (evaluate before Step 2, only when a diff exists)**

Check both conditions:

1. **No tool output** — every Phase 0 tool returned NOT RUN, exit 127, or an empty result set (npm audit ENOLOCK counts as NOT RUN; license-checker returning `{}` counts as empty).
2. **No JS/HTML surface area** — the diff contains no `.js`, `.ts`, `.jsx`, `.tsx`, `.mjs`, `.cjs`, `.html`, `.htm` files and no `package.json`, `package-lock.json`, or `yarn.lock` changes.

If **both** are true: output the following and stop. Do not launch sub-tasks.

> `No high-confidence security vulnerabilities found in this changeset. Scope: no npm/JS/HTML surface area — all Phase 0 tool scans returned no applicable output.`

If either condition is false (a tool produced output, or JS/TS/HTML files are in the diff), proceed to Step 2.

---

**Step 2 — Parallel Analysis (two sub-tasks, launched simultaneously)**

*Sub-task A — Semantic Analysis:*
The prompt must include: the full git diff, all 8 Phase 2 categories with their sub-questions, the codebase context from Phase 1, and the complete Hard Exclusions list.
Instruction to sub-task: work through each of the 8 categories against the diff and return candidate findings. Each finding must include: file path, line number, OWASP ID, Phase 2 category (e.g. `2.2 Authorization Model Correctness`), confidence score (1–10), and a one-paragraph description covering the vulnerability and its exploit path.

*Sub-task B — Tool Output Triage:*
The prompt must include: the complete raw output from all Phase 0 tool scans (including license-checker and socket.dev if they ran), the codebase context from Phase 1, and the complete Hard Exclusions list.
Instruction to sub-task: for each tool finding return: tool name, file or package name, line if available, classification (TRUE_POSITIVE or FALSE_POSITIVE), one-sentence rationale, and for true positives a description of the specific business impact in this application. For license findings, note the license type, the affected package, and whether it is a direct or transitive dependency. For socket.dev findings, note the specific supply chain risk category.

**Step 3 — Final Report**
Discard any semantic finding with confidence < 2. Discard any tool finding classified FALSE_POSITIVE. Format surviving findings using the Output Format above — Section A for semantic findings, Section B for enriched tool findings. Output the report to a file for human review.  If this is an interactive session with the user, ask the user for input on challenging areas or guidance.
