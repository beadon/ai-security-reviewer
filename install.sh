#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_SRC="$SCRIPT_DIR/.claude/commands"
WORKFLOW_SRC="$SCRIPT_DIR/.github/workflows/security-scan.yml"

# ── Colours ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}  !${RESET} $*"; }
fail() { echo -e "${RED}  ✗${RESET} $*"; }
info() { echo -e "  $*"; }

# ── Platform detection ─────────────────────────────────────────────────────
IS_MAC=false
[[ "$OSTYPE" == darwin* ]] && IS_MAC=true

has() { command -v "$1" &>/dev/null; }

# ── Package manager helpers ────────────────────────────────────────────────
brew_install()  { brew install "$1" 2>/dev/null; }
pip_install()   { python3 -m pip install --quiet --upgrade "$1"; }
npm_install()   { npm install -g --quiet "$1"; }

try_install() {
  local name="$1"; local brew_pkg="${2:-}"; local pip_pkg="${3:-}"; local npm_pkg="${4:-}"
  if $IS_MAC && [ -n "$brew_pkg" ] && has brew; then
    brew_install "$brew_pkg" && return 0
  fi
  if [ -n "$pip_pkg" ] && has python3; then
    pip_install "$pip_pkg" && return 0
  fi
  if [ -n "$npm_pkg" ] && has npm; then
    npm_install "$npm_pkg" && return 0
  fi
  fail "$name: no suitable installer found (need brew, python3, or npm)"
  return 1
}

# ── Dependency definitions ─────────────────────────────────────────────────
#
# Each entry: check_cmd | display_name | brew_pkg | pip_pkg | npm_pkg | optional
#
# Required tools are installed automatically.
# Optional tools (socket.dev) are flagged but not installed without --with-socket.

check_deps() {
  local install_missing="${1:-false}"
  local with_socket="${2:-false}"
  local missing=0

  echo ""
  echo "── Prerequisites ──────────────────────────────────────────────────"

  for tool in "gh:GitHub CLI:gh:::" "npm:npm (Node.js)::::" "python3:Python 3::::"; do
    local cmd="${tool%%:*}"; local label="${tool#*:}"; label="${label%%:*}"
    if has "$cmd"; then
      ok "$label"
    else
      fail "$label — required, install from https://nodejs.org / https://cli.github.com / https://python.org"
      (( missing++ )) || true
    fi
  done

  echo ""
  echo "── Code-level tools (/security-review) ───────────────────────────"

  _check_tool "semgrep"                    "Semgrep"                  "semgrep"      "semgrep"               ""                          "$install_missing"
  _check_tool "gitleaks"                   "gitleaks"                 "gitleaks"     ""                      ""                          "$install_missing"
  _check_tool "njsscan"                    "njsscan"                  ""             "njsscan"               ""                          "$install_missing"
  _check_tool "retire"                     "retire.js"                ""             ""                      "retire"                    "$install_missing"
  _check_tool "license-checker-rseidelsohn" "license-checker"         ""             ""                      "license-checker-rseidelsohn" "$install_missing"
  _check_tool "scancode"                   "scancode-toolkit"         ""             "scancode-toolkit"      ""                          "$install_missing"

  echo ""
  echo "── Infrastructure tools (/arch-review) ────────────────────────────"

  _check_tool "checkov"                    "Checkov"                  "checkov"      "checkov"               ""                          "$install_missing"
  _check_tool "hadolint"                   "hadolint"                 "hadolint"     ""                      ""                          "$install_missing"
  _check_tool "trivy"                      "Trivy"                    "trivy"        ""                      ""                          "$install_missing"
  _check_tool "tflint"                     "tflint"                   "tflint"       ""                      ""                          "$install_missing"
  _check_tool "ansible-lint"               "ansible-lint"             ""             "ansible-lint"          ""                          "$install_missing"

  echo ""
  echo "── Optional tools ──────────────────────────────────────────────────"

  if $with_socket; then
    _check_tool "socket"                   "socket.dev CLI"           ""             ""                      "@socketsecurity/cli"       "$install_missing"
    if [ -z "${SOCKET_API_KEY:-}" ]; then
      warn "socket.dev: SOCKET_API_KEY not set — add to your environment or repo secrets"
    fi
  else
    if has socket; then
      ok "socket.dev CLI (installed)"
    else
      info "socket.dev CLI — not installed (rerun with --with-socket to install)"
    fi
  fi

  echo ""
  if [ "$missing" -gt 0 ]; then
    fail "$missing prerequisite(s) missing — install them before proceeding"
    return 1
  fi
}

_check_tool() {
  local cmd="$1" label="$2" brew_pkg="$3" pip_pkg="$4" npm_pkg="$5" do_install="$6"

  if has "$cmd"; then
    ok "$label ($(command -v "$cmd"))"
    return 0
  fi

  if [ "$do_install" = "true" ]; then
    info "$label — not found, installing..."
    if try_install "$label" "$brew_pkg" "$pip_pkg" "$npm_pkg"; then
      ok "$label installed"
    else
      fail "$label — installation failed, some scans will be skipped"
    fi
  else
    warn "$label — not installed (skills will skip this scan)"
  fi
}

# ── Inspection tool permissions ────────────────────────────────────────────
# Writes read-only analysis tool permissions to .claude/settings.json so that
# sub-task agents (python3, sed, awk, jq, find, etc.) don't prompt mid-review.
configure_permissions() {
  local settings_file="$1"
  local settings_dir
  settings_dir="$(dirname "$settings_file")"

  if ! has python3; then
    warn "python3 not found — skipping settings.json permissions config"
    warn "Add inspection tool permissions to $settings_file manually if needed"
    return 0
  fi

  mkdir -p "$settings_dir"

  python3 - "$settings_file" \
    "Bash(python3:*)" "Bash(python:*)" "Bash(sed:*)" "Bash(awk:*)" "Bash(jq:*)" \
    "Bash(find:*)" "Bash(xargs:*)" "Bash(wc:*)" "Bash(sort:*)" "Bash(uniq:*)" \
    "Bash(cut:*)" "Bash(tr:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(cat:*)" \
    "Bash(stat:*)" "Bash(file:*)" <<'PYEOF'
import json, sys, os
settings_file = sys.argv[1]
new_tools = sys.argv[2:]
s = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        s = json.load(f)
existing = s.setdefault("permissions", {}).setdefault("allow", [])
added = [t for t in new_tools if t not in existing]
existing.extend(added)
with open(settings_file, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
print(len(added))
PYEOF

  local result=$?
  if [ $result -eq 0 ]; then
    ok "Inspection tool permissions configured in $settings_file"
    info "Sub-task agents (python3, sed, awk, jq, find, etc.) will run without per-command prompts"
  else
    warn "Could not update $settings_file — sub-task agents may prompt for each command"
  fi
}

# ── Skill installation ─────────────────────────────────────────────────────
install_skills() {
  local dest="$1"
  local version
  version="$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "development")"
  mkdir -p "$dest"
  for f in "$COMMANDS_SRC"/*.md; do
    sed "s/{{VERSION}}/$version/g" "$f" > "$dest/$(basename "$f")"
  done
  echo ""
  ok "Skills installed to $dest (version: $version)"
  info "/security-review  /arch-review  /full-review"

  # Configure inspection tool permissions so sub-agents don't prompt mid-review.
  # settings.json lives one level above the commands/ directory.
  local settings_dir
  settings_dir="$(dirname "$dest")"
  echo ""
  echo "── Inspection tool permissions ─────────────────────────────────────"
  configure_permissions "$settings_dir/settings.json"
}

# ── CI workflow installation ───────────────────────────────────────────────
install_ci() {
  local project="$1"
  local dest="$project/.github/workflows"
  mkdir -p "$dest"
  cp "$WORKFLOW_SRC" "$dest/security-scan.yml"
  echo ""
  ok "CI workflow installed to $dest/security-scan.yml"
  info "Commit it to your repo — it runs on every pull request."
  info "Optional: add SOCKET_API_KEY to your repo secrets for socket.dev scanning."
}

# ── Usage ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

AI Security Reviewer — installer

Usage:
  install.sh --global   [--with-deps] [--with-socket]
  install.sh --project  <path> [--with-deps] [--with-socket]
  install.sh --ci       <path>
  install.sh --all      <path> [--with-deps] [--with-socket]
  install.sh --check-deps [--with-socket]

Options:
  --global              Install skills to ~/.claude/commands/ (available in all projects)
  --project <path>      Install skills to <path>/.claude/commands/
  --ci <path>           Copy CI workflow to <path>/.github/workflows/
  --all <path>          Install skills + CI workflow to <path>
  --check-deps          Check which scanning tools are installed without installing
  --with-deps           Install missing scanning tools automatically
  --with-socket         Include socket.dev CLI in dependency check/install

Examples:
  ./install.sh --global --with-deps
  ./install.sh --all ~/work/my-app --with-deps --with-socket
  ./install.sh --check-deps
  ./install.sh --ci ~/work/my-app

After installing, invoke skills in Claude Code:
  /security-review    — npm/JS code-level review
  /arch-review        — infrastructure and IaC review
  /full-review        — both in parallel, unified report

EOF
  exit 1
}

# ── Argument parsing ───────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

MODE=""
TARGET=""
WITH_DEPS=false
WITH_SOCKET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --global)      MODE="global" ;;
    --project)     MODE="project"; TARGET="${2:-}"; shift ;;
    --ci)          MODE="ci";      TARGET="${2:-}"; shift ;;
    --all)         MODE="all";     TARGET="${2:-}"; shift ;;
    --check-deps)  MODE="check" ;;
    --with-deps)   WITH_DEPS=true ;;
    --with-socket) WITH_SOCKET=true ;;
    -h|--help)     usage ;;
    *) echo "Error: unknown option '$1'"; usage ;;
  esac
  shift
done

[ -z "$MODE" ] && usage
[[ "$MODE" =~ ^(project|ci|all)$ ]] && [ -z "$TARGET" ] && { echo "Error: $MODE requires a path"; usage; }

# ── Main ───────────────────────────────────────────────────────────────────
case "$MODE" in
  check)
    check_deps false "$WITH_SOCKET"
    ;;
  global)
    check_deps "$WITH_DEPS" "$WITH_SOCKET"
    install_skills "$HOME/.claude/commands"
    ;;
  project)
    check_deps "$WITH_DEPS" "$WITH_SOCKET"
    install_skills "$TARGET/.claude/commands"
    ;;
  ci)
    install_ci "$TARGET"
    ;;
  all)
    check_deps "$WITH_DEPS" "$WITH_SOCKET"
    install_skills "$TARGET/.claude/commands"
    install_ci "$TARGET"
    ;;
esac
