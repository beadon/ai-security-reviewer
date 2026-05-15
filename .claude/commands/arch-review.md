---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Bash(checkov:*), Bash(hadolint:*), Bash(trivy:*), Bash(tflint:*), Bash(ansible-lint:*), Bash(which:*), Read, Glob, Grep, LS, Task
description: Infrastructure and deployment security review — IaC, containers, CI/CD, and cloud configuration
version: "{{VERSION}}"
---

> Skill version: !`git describe --tags --abbrev=0 2>/dev/null || echo "development"`

## Role

This is a **two-layer security review pipeline for infrastructure and deployment configuration**.

**Layer 1 — Tools (you run these in Phase 0):** Static analysis of IaC files, container definitions, and CI/CD configuration. Checkov, hadolint, trivy, tflint, and ansible-lint cover known misconfiguration patterns faster and more exhaustively than any LLM.

**Layer 2 — Semantic analysis (your actual job):** Triage tool findings with deployment context, then find what no static analyzer can catch: privilege escalation chains across IAM roles, network segmentation mismatches against application topology, secret handling anti-patterns, CI/CD pipeline integrity gaps, and cross-service trust exposure.

**Do NOT re-derive what the tools already report.** If Checkov flagged a missing encryption setting, your job is to assess the business impact in this specific deployment — not to re-explain what unencrypted storage means.

**Tool constraints:** Only use the tools listed in `allowed-tools`. Do NOT write files or run arbitrary bash commands beyond those listed.

---

## Branch Context

GIT STATUS:
```
!`git status`
```

IaC FILES MODIFIED:
```
!`git diff --name-only origin/HEAD... | grep -E '\.(tf|tfvars|yaml|yml|pp|sls|rb|bicep|template)$|Dockerfile|docker-compose|Jenkinsfile|Berksfile'`
```

COMMITS:
```
!`git log --no-decorate origin/HEAD...`
```

IaC DIFF CONTENT:
```
!`git diff --merge-base origin/HEAD -- '*.tf' '*.tfvars' '*.yaml' '*.yml' '*.pp' '*.sls' 'Dockerfile*' 'docker-compose*' '.github/workflows/*' 'Jenkinsfile' '*.bicep' '*.template'`
```

---

## Phase 0 — Automated Tool Scans

Run each command below using your bash tool. If a tool is not installed, record `[NOT RUN — not installed]` and continue.

### Checkov (primary IaC scanner)
```
checkov -d . --output json --quiet 2>/dev/null
```
Covers: Terraform, CloudFormation, Kubernetes, Dockerfile, Ansible, Helm, Bicep, GitHub Actions — known misconfiguration rules across all major IaC formats (OWASP A01, A02, A05).

### hadolint (Docker-specific)
```
hadolint --format json $(find . -name 'Dockerfile*' -not -path '*/node_modules/*' -not -path '*/.git/*') 2>/dev/null
```
Covers: Dockerfile best practices, insecure `ADD` URL fetches, missing `USER` directives, mutable base image tags, dangerous `RUN` patterns (OWASP A05, A08).

### Trivy config scan
```
trivy config --format json . 2>/dev/null
```
Covers: Kubernetes, Terraform, CloudFormation, Dockerfile — complementary rule set to Checkov with different coverage areas (OWASP A01, A05, A06).

### tflint (Terraform-specific)
```
tflint --format json 2>/dev/null
```
Covers: Terraform provider-specific rules, deprecated resources, misconfigured arguments that Checkov's generic rules miss (OWASP A05).

### ansible-lint (if Ansible files are present)
First check if Ansible files exist:
```
which ansible-lint 2>/dev/null && find . -name '*.yml' -path '*/playbooks/*' -o -name '*.yml' -path '*/roles/*' -o -name '*.yml' -path '*/tasks/*' 2>/dev/null | head -5
```
If files are found and ansible-lint is available:
```
ansible-lint --format json 2>/dev/null
```
Covers: Ansible playbook security — command injection in shell tasks, privilege escalation misuse, insecure module usage (OWASP A03, A05).

---

## Phase 1 — Deployment Context

Use file-reading and search tools to understand the deployment before analyzing the diff. Establish:

- **Deployment targets:** What formats are in use? (Kubernetes, ECS, Lambda, VMs, bare Docker, Ansible-managed hosts)
- **Cloud provider:** AWS, GCP, Azure, or hybrid? What managed services are configured?
- **Secrets management:** How are secrets injected? (env vars in task definitions, K8s Secrets, Vault references, AWS Secrets Manager refs, SSM Parameter Store)
- **Network topology:** What VPCs, subnets, security groups, or network policies define the segmentation model? What can talk to what?
- **IAM/RBAC model:** What roles, service accounts, or instance profiles exist? What do they grant?
- **CI/CD system:** GitHub Actions, Jenkins, GitLab CI, CircleCI? What permissions does the pipeline run with?
- **Container registry:** Public Docker Hub, ECR, GCR, ACR, or private registry? Are images pinned to digests?

---

## Phase 2 — Semantic Analysis (what tools cannot catch)

Work through each category below against the IaC diff. These require understanding the full deployment topology and IAM graph — things no static rule can evaluate.

### 2.1 · IAM and RBAC Privilege Escalation Chains
- Can role A assume role B, which can assume role C, which has admin-level access? Tools check individual policies; they cannot evaluate multi-hop chains.
- Does a Lambda execution role, ECS task role, or EC2 instance profile have `iam:PassRole` or `iam:CreateAccessKey` permissions that enable escalation beyond the role's stated purpose?
- Does a Kubernetes ServiceAccount have ClusterRole bindings when namespace-scoped RoleBindings would be sufficient?
- Can a low-privilege CI/CD pipeline role escalate by triggering a higher-privilege pipeline or Lambda?

### 2.2 · Cross-Service and Cross-Account Trust Exposure
- Do resource-based policies (S3 bucket policy, SQS queue policy, KMS key policy, ECR repository policy) grant access to a principal broader than intended — e.g., `"Principal": "*"` with an insufficient condition, or an account ID that is too broad?
- Does a cross-account role trust relationship have conditions (`aws:PrincipalArn`, `aws:PrincipalAccount`) that are weaker than the sensitivity of the resources it grants access to?
- Are there assume-role trust policies that accept wildcards on external IDs or that are missing external ID conditions entirely?

### 2.3 · Secret Handling Anti-Patterns
- Are secrets passed as plaintext environment variables in task definitions, pod specs, docker-compose files, or CI/CD workflows — even if the value is a reference that looks safe?
- Is a Kubernetes Secret created from a ConfigMap or other resource that itself contains the plaintext value?
- Are CI/CD workflow steps printing environment variables (`env`, `printenv`, `echo $SECRET`) that would expose secrets in logs?
- Are build arguments (`ARG`) used to pass secrets into a Dockerfile image layer where they become permanently embedded?

### 2.4 · Network Segmentation vs. Application Topology Mismatch
- Does the security group, network policy, or firewall rule allow traffic between services that, based on the application architecture, should not communicate directly?
- Is a management port (SSH/22, RDP/3389, database ports) reachable from a broader CIDR than the specific bastion or admin subnet?
- Does a Kubernetes NetworkPolicy allow ingress from `namespaceSelector: {}` (all namespaces) when it should be scoped to a specific namespace?

### 2.5 · Container Security Context (beyond Checkov rules)
- Are dangerous Linux capabilities added (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`) even if `privileged: false`?
- Are host path mounts pointing to sensitive directories: `/var/run/docker.sock`, `/etc/`, `/proc/`, `/sys/`, `/root/`?
- Is `allowPrivilegeEscalation: false` missing on containers that run as root by default and have no explicit `runAsNonRoot: true`?
- Are seccomp and AppArmor/SELinux profiles disabled or set to `Unconfined` on containers handling untrusted input?

### 2.6 · CI/CD Pipeline Integrity
- Are GitHub Actions, GitLab CI jobs, or other pipeline steps using mutable version references (`:latest`, `@v3`, branch names) instead of pinned SHA digests?
- Does the workflow grant write permissions (`contents: write`, `id-token: write`, `packages: write`) broader than the minimum needed for the specific job?
- Can a PR from a fork trigger a workflow that has access to repository secrets? (Check `pull_request_target` with untrusted code checkout)
- Are there workflow steps that `git checkout` user-supplied refs and then execute code from that ref in a privileged context?

### 2.7 · Image Provenance and Supply Chain
- Does any `FROM` instruction use a mutable tag (`:latest`, `:18`, `:lts`) instead of a digest-pinned reference (`@sha256:...`)?
- Are base images pulled from Docker Hub public repositories rather than a verified private registry or a vendor-controlled namespace?
- Does any `ADD` instruction fetch from an external URL rather than copying from the build context?
- Are multi-stage builds used, but a debug or build stage with extra tools is accidentally used as the final stage?

### 2.8 · Data Classification and Encryption Alignment
- Given what the application handles (from the code context), is there storage (S3 buckets, RDS instances, EBS volumes, DynamoDB tables) that likely holds PII, credentials, or financial data but is configured without encryption at rest or in transit?
- Does a newly added data store lack a clear data classification in its configuration (tags, labels, naming convention) that would subject it to the organisation's retention and encryption policies?

---

## Phase 3 — Tool Output Triage

Review the captured output from Phase 0. For each tool finding:

1. **Classify:** TRUE_POSITIVE or FALSE_POSITIVE, given the deployment context from Phase 1.
2. **Enrich true positives:** What is the actual blast radius in this specific deployment? Who can exploit it, and from where?
3. **Identify patterns:** Does a single misconfiguration indicate a systematic gap (e.g., all security groups in this account follow the same overly-permissive pattern)?
4. **Discard false positives:** Note why briefly (e.g., "Checkov CKV_K8S_30 fired on a test pod spec — excluded per rule 5") and move on.

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
* Affects: [Terraform | Kubernetes | Docker | CI/CD | Ansible | ...]
* Description: [What the misconfiguration is and exactly where it appears]
* Exploit Scenario: [Concrete attacker steps → resulting impact in this deployment]
* Recommendation: [Specific fix; reference existing patterns in this codebase where possible]
```

### Section B — Tool Findings (Triaged and Enriched)

Confirmed true positives from Phase 3. Do not copy tool output verbatim — add deployment context.

```
# B[N]: [Short Title] — `path/to/file:line`

* Severity: High | Medium | Low
* OWASP: A0X – [Category Name]
* Source: Checkov | hadolint | Trivy | tflint | ansible-lint
* Rule: [Rule ID, e.g. CKV_K8S_30]
* Affects: [Terraform | Kubernetes | Docker | CI/CD | Ansible | ...]
* Business Impact: [Why this matters specifically in this deployment]
* Recommendation: [Specific fix]
```

If no findings survive filtering: output `No high-confidence infrastructure security vulnerabilities found in this changeset.`

---

## Severity and Confidence

| Severity | Criteria |
|----------|----------|
| **High** | Directly exploitable: privilege escalation, secrets exposure, public data breach, container escape |
| **Medium** | Requires specific conditions but significant impact when met |
| **Low** | Defense-in-depth — only include if confidence is 9 or 10 |

| Confidence | Meaning |
|------------|---------|
| 9–10 | Certain exploit path; attack is concrete and impact is clear |
| 8–9  | Clear misconfiguration with a known exploitation method |
| < 8  | Do NOT report |

**Minimum threshold to report: 8/10**

---

## Hard Exclusions

Do NOT report the following:

1. Missing hardening measures without a concrete exploit path — only report concrete misconfigurations.
2. Outdated base image versions with known CVEs — tracked by Trivy and dependabot separately; do not duplicate.
3. Missing audit logging or CloudTrail configuration — tracked separately.
4. Checkov, Trivy, or tflint findings in `test/`, `tests/`, `examples/`, `fixtures/`, or `sample/` directories.
5. Theoretical network paths that require multiple simultaneous compensating control failures.
6. Best practice gaps (e.g., missing resource tagging, non-standard naming conventions) without security impact.
7. Missing rate limiting or resource quotas on non-security-critical services.
8. Docker layer optimisation issues that have no security impact.
9. Linting issues in IaC that are style or maintainability concerns only.
10. Missing monitoring or alerting configuration — not a direct security vulnerability.
11. Findings in vendored or generated code (`.terraform/`, `node_modules/`, `vendor/`).

### Precedents
- A `0.0.0.0/0` ingress rule on port 443 or 80 is expected for public-facing load balancers — do not flag unless the service is not intended to be public.
- Kubernetes `emptyDir` volumes are ephemeral and safe — only flag persistent volume claims or host path mounts.
- `runAsNonRoot: true` on a pod spec applies to all containers in the pod; do not flag individual containers in that pod separately.
- A missing `securityContext` on an init container is lower severity than on the main application container.

---

## Execution Instructions

**Step 1 — Tool Scans and Context (sequential, must complete before Step 2)**
Run all Phase 0 tool scans. Then complete Phase 1 deployment context research. Record all output before proceeding.

**Step 2 — Parallel Analysis (two sub-tasks, launched simultaneously)**

*Sub-task A — Semantic Analysis:*
Prompt must include: the full IaC diff, all 8 Phase 2 categories with their sub-questions, the deployment context from Phase 1, and the complete Hard Exclusions list.
Instruction: work through each of the 8 categories against the diff and return candidate findings. Each finding must include: file path, line number, OWASP ID, Phase 2 category, confidence score (1–10), and a one-paragraph description of the misconfiguration and its exploit path.

*Sub-task B — Tool Output Triage:*
Prompt must include: the complete raw output from all Phase 0 tool scans, the deployment context from Phase 1, and the complete Hard Exclusions list.
Instruction: for each tool finding return: tool name, rule ID, file, line, classification (TRUE_POSITIVE or FALSE_POSITIVE), one-sentence rationale, and for true positives the specific blast radius in this deployment.

**Step 3 — Final Report**
Discard any semantic finding with confidence < 8. Discard any tool finding classified FALSE_POSITIVE. Format surviving findings using the Output Format above. Output the report and nothing else.
