# AI Security Reviewer

A two-layer security review pipeline for npm/JavaScript codebases and their deployment infrastructure, powered by Claude Code.

**Layer 1 — Automated tools:** Purpose-built scanners handle pattern-matching, known CVEs, hardcoded secrets, license compliance, IaC misconfigurations, and supply chain threats. These run first and produce structured findings.

**Layer 2 — AI semantic analysis:** Claude triages tool output with business context, then analyzes what no pattern-matcher can catch: business logic flaws, authorization model errors, second-order vulnerabilities, privilege escalation chains, and cross-boundary trust violations.

## Three Skills

| Skill | Command | Scope |
|-------|---------|-------|
| `security-review.md` | `/security-review` | npm/JS code — injection, auth, business logic, supply chain |
| `arch-review.md` | `/arch-review` | IaC, containers, CI/CD, cloud config — Terraform, K8s, Docker, Ansible |
| `full-review.md` | `/full-review` | Orchestrator — runs both above in parallel, merges into one report |

For most PR reviews, use `/full-review`. Use the individual skills when you want a focused, faster scan of one layer only.

---

## Prerequisites

- [Claude Code](https://claude.ai/code) installed and authenticated
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated (`gh auth login`)

The security scanning tools (Semgrep, gitleaks, njsscan) are **optional for local use**. If not installed, the AI analysis proceeds without their output. See [CI Workflow](#ci-workflow) for running tools in a reproducible environment.

**Optional commercial tool:** [socket.dev](https://socket.dev) provides supply chain security analysis. It requires a `SOCKET_API_KEY` environment variable. Free for public repositories; paid plan required for private repositories. Without the key, the skill skips this scan and notes it in the report. See [socket.dev setup](#socketdev-setup) below.

---

## Installation

```bash
git clone https://github.com/beadon/ai-security-reviewer
cd ai-security-reviewer
```

### Scanning tools

The installer can install all scanning tools for you:

```bash
./install.sh --global --with-deps
```

Or install them manually. On macOS with Homebrew:

```bash
# Code-level tools (/security-review)
brew install semgrep gitleaks
pip install njsscan scancode-toolkit
npm install -g retire

# Infrastructure tools (/arch-review)
brew install checkov hadolint trivy tflint
pip install ansible-lint

# License checker (no install needed — runs via npx)
```

`pip install njsscan` installs the njsscan binary into your Python environment's `bin/` directory — make sure that directory is on your `PATH` (e.g. `$(python3 -m site --user-base)/bin` for user installs, or your virtualenv's `bin/`).

Then run the installer for your scenario:

```bash
# Make available across all projects
./install.sh --global

# Install to one specific project (skills only)
./install.sh --project /path/to/your/project

# Install skills + CI workflow to a project (Scenario 3)
./install.sh --all /path/to/your/project
```

The installer copies the skill files from `.claude/commands/` to the correct location and the CI workflow from `.github/workflows/` to the target repo. The orchestrator (`/full-review`) reads the other two skill files at runtime — all three must be installed in the same directory.

---

## Usage

### Scenario 1 — Review a Pull Request (recommended)

Check out the PR branch locally, then invoke the full review. This runs both code-level and infrastructure analysis in parallel.

```bash
gh pr checkout <PR-number>
```

Then in Claude Code:

```
/full-review
```

For a faster, focused scan of one layer only:

```
/security-review    # code only
/arch-review        # infrastructure only
```

The report covers only the changes introduced by that PR, not the entire codebase.

**With socket.dev (optional):** If `SOCKET_API_KEY` is set in your environment, the skill automatically runs a supply chain scan as part of Phase 0. To configure it:

```bash
export SOCKET_API_KEY=your_api_key_here
```

**With license-checker (no setup required):** Runs automatically via `npx` — no installation needed. Flags any dependency with a copyleft or unknown license introduced by the PR.

---

### Scenario 2 — Review a Full Repository or Arbitrary Branch

Clone any public or private repository you have access to, then run the review from within it.

```bash
# Clone and review the default branch
gh repo clone <org>/<repo> /tmp/target
cd /tmp/target
```

For a specific branch:

```bash
gh repo clone <org>/<repo> /tmp/target -- --branch <branch-name>
cd /tmp/target
```

Then in Claude Code (opened in `/tmp/target`):

```
/full-review
```

This scenario is particularly useful for supply chain and license audits of a dependency or third-party repo before adopting it. Both license-checker and socket.dev (if configured) will scan the full dependency tree, and arch-review will inspect any IaC files present.

**Note:** When reviewing a full repository rather than a PR diff, the git diff commands produce no output. Both skills proceed using tool scan results and semantic analysis of the codebase as a whole.

---

### Scenario 3 — CI-Integrated Review (recommended for teams)

Running tools locally is fragile — tools may not be installed, versions may differ, and results are not reproducible across machines. The recommended team deployment separates tool execution from AI analysis:

```
PR opened
  → GitHub Actions runs all scanning tools (code + IaC) in a clean environment
  → socket.dev GitHub App posts its own PR comment (if installed)
  → All other tool results posted as a structured PR comment by the workflow
  → Developer runs /full-review in Claude Code
  → Orchestrator spawns parallel code-level + infrastructure sub-tasks
  → Each sub-task reads tool results from CI, adds semantic analysis
  → Unified report produced
```

**Setup:**

1. Add the GitHub Actions workflow to your target repository (see [CI Workflow](#ci-workflow) below).
2. *(Optional)* Install the [Socket GitHub App](https://socket.dev) on the repository. It runs automatically on every PR and posts supply chain findings as its own comment — no workflow step required.
3. When reviewing a PR, check it out and run `/full-review`. Each sub-skill will detect and consume the tool results posted by CI.

---

## CI Workflow

The workflow file is at [`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml) in this repo. Install it to your target repository with:

```bash
./install.sh --ci /path/to/your/project
# or as part of a full install:
./install.sh --all /path/to/your/project
```

It runs on every pull request, executes all scanning tools in a clean environment, and posts results as a PR comment that `/full-review` can consume.

<details>
<summary>View workflow YAML</summary>

```yaml
name: Security Scan

on:
  pull_request:
    branches: [main, master]

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      contents: read

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: npm audit
        run: npm audit --json > /tmp/npm-audit.json 2>/dev/null || true

      - name: Semgrep
        uses: semgrep/semgrep-action@v1
        with:
          config: >-
            p/javascript
            p/nodejs
            p/secrets
          output: /tmp/semgrep.json
          output-format: json
        continue-on-error: true

      - name: gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        continue-on-error: true

      - name: njsscan
        run: |
          pip install njsscan --quiet
          njsscan --json . > /tmp/njsscan.json 2>/dev/null || true

      - name: Checkov (IaC)
        uses: bridgecrewio/checkov-action@v12
        with:
          output_format: json
          output_file_path: /tmp/checkov.json
        continue-on-error: true

      - name: hadolint (Dockerfile)
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          format: json
          output-file: /tmp/hadolint.json
        continue-on-error: true

      - name: Trivy config scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: config
          format: json
          output: /tmp/trivy-config.json
        continue-on-error: true

      - name: License Checker
        run: npx license-checker-rseidelsohn --json --excludePrivatePackages > /tmp/license-checker.json 2>/dev/null || true

      - name: Socket.dev CLI scan
        if: env.SOCKET_API_KEY != ''
        env:
          SOCKET_API_KEY: ${{ secrets.SOCKET_API_KEY }}
        run: |
          npm install -g @socketsecurity/cli --quiet
          socket scan create --json . > /tmp/socket.json 2>/dev/null || true

      - name: Post results as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return '{}'; } };

            const body = [
              '<!-- security-scan-results -->',
              '## Security Scan Results',
              '### npm audit',
              '```json',
              read('/tmp/npm-audit.json'),
              '```',
              '### Semgrep',
              '```json',
              read('/tmp/semgrep.json'),
              '```',
              '### njsscan',
              '```json',
              read('/tmp/njsscan.json'),
              '```',
              '### License Checker',
              '```json',
              read('/tmp/license-checker.json'),
              '```',
              '### Socket.dev',
              '```json',
              read('/tmp/socket.json'),
              '```',
              '### Checkov (IaC)',
              '```json',
              read('/tmp/checkov.json'),
              '```',
              '### hadolint',
              '```json',
              read('/tmp/hadolint.json'),
              '```',
              '### Trivy config',
              '```json',
              read('/tmp/trivy-config.json'),
              '```',
            ].join('\n');

            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const existing = comments.find(c => c.body.includes('<!-- security-scan-results -->'));

            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body,
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body,
              });
            }
```

</details>

---

## socket.dev Setup

socket.dev is optional but adds meaningful supply chain coverage that no other tool in this stack provides.

**Free tier (public repos):** Install the [Socket GitHub App](https://socket.dev) on your repository. It runs automatically on every PR with no API key or workflow step needed.

**Paid plan (private repos):** The GitHub App requires a paid plan for private repositories. Alternatively, use the CLI in Scenarios 1 and 2:

```bash
export SOCKET_API_KEY=your_api_key_here  # add to ~/.zshrc or ~/.bashrc
```

For CI (Scenario 3), add your key as a repository secret named `SOCKET_API_KEY` in GitHub → Settings → Secrets and variables → Actions. The workflow step runs conditionally only when the secret is present.

---

## What the Tools Cover

### Code-Level Tools (`/security-review`)

| Tool | Scope | Free? | OWASP |
|------|-------|-------|-------|
| `npm audit` | Known CVEs in the dependency tree | Yes (built-in) | A06 |
| Semgrep | Injection sinks, XSS, prototype pollution, hardcoded credentials | Yes (OSS) | A02, A03, A08 |
| gitleaks | Secrets and tokens in git history and diffs | Yes (OSS) | A02 |
| njsscan | Express/Node misconfigurations, missing security middleware | Yes (OSS) | A05, A07 |
| license-checker-rseidelsohn | Copyleft and unknown licenses in the dependency tree | Yes (OSS) | A06 |
| scancode-toolkit | Copyright notices and license identifiers in source file headers; detects GPL-contaminated code copied directly into the codebase | Yes (OSS) | A06 |
| socket.dev | Supply chain: malicious install scripts, typosquatting, new/unknown maintainers | Free for public repos; paid for private | A06 |

### Infrastructure Tools (`/arch-review`)

| Tool | Scope | Free? | OWASP |
|------|-------|-------|-------|
| Checkov | Terraform, CloudFormation, K8s, Dockerfile, Ansible, Helm, Bicep | Yes (OSS) | A01, A02, A05 |
| hadolint | Dockerfile best practices, insecure ADD/RUN patterns, mutable base tags | Yes (OSS) | A05, A08 |
| Trivy (config) | K8s, Terraform, CloudFormation, Dockerfile — complementary to Checkov | Yes (OSS) | A01, A05, A06 |
| tflint | Terraform provider-specific rules and deprecated resources | Yes (OSS) | A05 |
| ansible-lint | Ansible playbook security — shell injection, privilege escalation misuse | Yes (OSS) | A03, A05 |

## What the AI Covers (tools cannot catch these)

### Code-level (`/security-review`)

| Category | Examples |
|----------|---------|
| Business logic flaws | Operations out of sequence, one-time token reuse, state assumptions violated |
| Authorization model correctness | Authz after data fetch, check on wrong principal, branches that skip authz |
| Second-order injection | Data stored safely, retrieved and used dangerously in a different file |
| Cross-file trust boundary violations | Internal helper now called from a public handler without re-validation |
| Chained vulnerabilities | Two low-privilege operations composed to escalate privilege |
| Race conditions with business impact | TOCTOU on payments, role changes, quota enforcement |
| Semantic SSRF | User input influences outbound URL host/protocol across multiple files |
| Token and session logic | Missing claim validation, token replay across audiences |

### Infrastructure-level (`/arch-review`)

| Category | Examples |
|----------|---------|
| IAM privilege escalation chains | Role A → Role B → admin via multi-hop assume-role |
| Cross-service trust exposure | Resource policy granting access broader than intended |
| Secret handling anti-patterns | Plaintext env vars in task definitions, secrets in Dockerfile ARGs |
| Network segmentation mismatches | Security group allows DB access from all app servers, not just payment service |
| Container security context | Dangerous capabilities, host path mounts to `/var/run/docker.sock` |
| CI/CD pipeline integrity | Mutable action tags, `pull_request_target` with untrusted checkout |
| Image provenance | Mutable base tags, Docker Hub public images, `ADD` from URLs |
| Data classification alignment | Unencrypted storage for resources that likely hold PII or credentials |

---

## Output

The review produces a markdown report with two sections:

**Section A — Semantic Findings (AI-Detected):** Vulnerabilities the tools did not report, found through semantic reasoning about the codebase.

**Section B — Tool Findings (Triaged and Enriched):** Confirmed true positives from the automated scans, with business-specific impact added by the AI.

Each finding includes: severity (High/Medium/Low), OWASP category, confidence score, a concrete exploit scenario, and a specific remediation recommendation.

---

## Confidence Threshold

Findings below **8/10** confidence are suppressed. The goal is zero false positives surfaced to the developer — a missed finding is cheaper than alert fatigue.

---

## Security Lifecycle: Where This Tool Fits

This pipeline covers **pre-deployment, static analysis** — it runs against code and configuration files before anything ships. It answers: *is this safe to deploy?*

It is not a substitute for post-deployment scanning, which answers: *is the running system currently secure?*

```
Code written → PR opened → /full-review (this tool) → merged → deployed → post-deployment scanning
                                    ↑                                              ↑
                         Static: code + IaC files                     Dynamic: live systems
                         Catches what will be introduced               Catches what is currently exposed
```

### Post-Deployment Tools (out of scope for this pipeline)

| Tool | What it scans | When to run |
|------|--------------|-------------|
| **Nessus** (Tenable) | Live hosts — open ports, service versions, OS patch levels, authenticated configuration checks | After deployment; scheduled periodic scans of staging and production |
| **OWASP ZAP** | Running web application — HTTP attack surface, auth flows, session handling | Against a deployed staging environment; part of a release gate |
| **Burp Suite** | Running web application — deep HTTP/API testing, active scanning | Manual or automated against staging before major releases |
| **AWS Inspector / GCP Security Command Center / Azure Defender** | Cloud workloads — running EC2/container/serverless vulnerabilities and exposure | Continuous; enabled at the account level |
| **Trivy** (image scan mode) | Container images in a registry — CVEs in OS packages and application dependencies | On image push to registry; separate from the config scan this tool runs |

Nessus in particular operates by probing live IP addresses over the network — it requires a running target and network reachability, which makes it incompatible with a PR review workflow by design. The right place for it is a scheduled scan of your staging or production environment, or as a release gate check after deployment.

### Copyright and IP Scanning: What Belongs Where

| Tool | What it does | Fits in this pipeline? |
|------|-------------|----------------------|
| **scancode-toolkit** | Reads source file headers for copyright notices and license identifiers; detects GPL-contaminated code snippets copied into the codebase | Yes — in `security-review` Phase 0, scoped to changed files |
| **license-checker** | Reads `package.json` metadata to identify what license each npm dependency is under | Yes — already in `security-review` Phase 0 |
| **FOSSA** | Hosted service combining license compliance, copyright detection, and transitive obligation tracking; free tier for open source | Yes for per-PR (FOSSA GitHub App); full release-gate scans are better scheduled |
| **Black Duck** (Synopsys) | Enterprise-grade: deep snippet matching against a massive database, export control classification, full transitive obligation tracking | No — too slow for per-PR; belongs as a release gate scan on the full codebase |

The key distinction: `scancode-toolkit` and `license-checker` catch copyright and license issues *introduced by this PR* cheaply and quickly. Black Duck / FOSSA full scans audit the *entire codebase* comprehensively — right for a release gate or a scheduled compliance audit, wrong for a fast PR check.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on adding tools, new ecosystem skills, and submitting PRs.

This project is licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**. See [LICENSE](LICENSE). If you modify this project and expose it as a network service, you must publish your source under the same terms.
