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

# Ensure user-local binaries are findable during and after install
export PATH="$HOME/.local/bin:$PATH"

# ── Package manager helpers ────────────────────────────────────────────────
brew_install() { brew install "$1" 2>/dev/null; }

# apt_install: system-wide install via apt-get (requires sudo).
apt_install() { has sudo && has apt-get && sudo apt-get install -y --quiet "$1" 2>/dev/null; }

# pip_install: use pipx (isolated venv per tool, bypasses PEP 668).
# If pipx is absent and apt is available, install it first — one sudo prompt unlocks
# all Python CLI tools cleanly without touching system Python.
pip_install() {
  if ! has pipx && has apt-get && has sudo; then
    info "  installing pipx via apt..."
    sudo apt-get install -y --quiet pipx 2>/dev/null || true
    hash -r 2>/dev/null || true  # refresh PATH cache
  fi
  if has pipx; then
    pipx install --quiet "$1"
    return $?
  fi
  # Fallback: pip --user. Works on Python < 3.12; blocked on Debian 12+ by PEP 668.
  python3 -m pip install --quiet --user --upgrade "$1"
}

# Install npm packages to ~/.local/bin — avoids needing root.
npm_install() { npm install -g --quiet --prefix "$HOME/.local" "$1"; }

# _stream_url / _download_file: prefer curl, fall back to wget.
_stream_url()    { has curl && curl -sL "$1"          || has wget && wget -qO-  "$1"; }
_download_file() { has curl && curl -sL "$1" -o "$2"  || has wget && wget -q    "$1" -O "$2"; }

try_install() {
  local name="$1" brew_pkg="${2:-}" pip_pkg="${3:-}" npm_pkg="${4:-}" custom_fn="${5:-}"
  if $IS_MAC && [ -n "$brew_pkg" ] && has brew; then
    brew_install "$brew_pkg" && return 0
  fi
  if [ -n "$pip_pkg" ] && has python3; then
    pip_install "$pip_pkg" && return 0
  fi
  if [ -n "$npm_pkg" ] && has npm; then
    npm_install "$npm_pkg" && return 0
  fi
  if [ -n "$custom_fn" ] && { has curl || has wget; }; then
    "$custom_fn" && return 0
  fi
  fail "$name: no suitable installer found"
  return 1
}

# ── GitHub release binary installers ──────────────────────────────────────
# Used for tools that ship as static binaries (not pip/npm/brew packages on Linux).

_latest_tag() {
  local repo="$1"
  if has gh; then
    gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null
  else
    _stream_url "https://api.github.com/repos/$repo/releases/latest" \
      | grep '"tag_name"' | head -1 \
      | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
  fi
}

_install_gitleaks() {
  local tag version os arch dest="$HOME/.local/bin"
  tag=$(_latest_tag "gitleaks/gitleaks") || return 1
  [[ -z "$tag" ]] && return 1
  version="${tag#v}"
  $IS_MAC && os="darwin" || os="linux"
  case "$(uname -m)" in x86_64) arch="x64";; aarch64|arm64) arch="arm64";; *) return 1;; esac
  mkdir -p "$dest"
  _stream_url "https://github.com/gitleaks/gitleaks/releases/download/${tag}/gitleaks_${version}_${os}_${arch}.tar.gz" \
    | tar -xz -C "$dest" gitleaks 2>/dev/null
}

_install_hadolint() {
  # Prefer apt (Debian Bookworm / Ubuntu 22.04+ include hadolint in main repo).
  apt_install hadolint && return 0
  # Binary download fallback.
  local tag os arch dest="$HOME/.local/bin"
  tag=$(_latest_tag "hadolint/hadolint") || return 1
  [[ -z "$tag" ]] && return 1
  $IS_MAC && os="Darwin" || os="Linux"
  case "$(uname -m)" in x86_64) arch="x86_64";; aarch64|arm64) arch="arm64";; *) return 1;; esac
  mkdir -p "$dest"
  _download_file "https://github.com/hadolint/hadolint/releases/download/${tag}/hadolint-${os}-${arch}" \
    "$dest/hadolint" && chmod +x "$dest/hadolint"
}

_install_trivy() {
  # Prefer official aquasecurity apt repo (system-wide, kept current by apt update).
  if ! $IS_MAC && has apt-get && has sudo && { has curl || has wget; }; then
    has gpg || apt_install gnupg
    local keyring="/usr/share/keyrings/trivy.gpg"
    _stream_url "https://aquasecurity.github.io/trivy-repo/deb/public.key" 2>/dev/null \
      | sudo gpg --dearmor -o "$keyring" 2>/dev/null
    echo "deb [signed-by=$keyring] https://aquasecurity.github.io/trivy-repo/deb generic main" \
      | sudo tee /etc/apt/sources.list.d/trivy.list >/dev/null
    sudo apt-get update -qq 2>/dev/null
    apt_install trivy && return 0
  fi
  # Binary download fallback (Mac or no apt).
  local tag version os arch dest="$HOME/.local/bin"
  tag=$(_latest_tag "aquasecurity/trivy") || return 1
  [[ -z "$tag" ]] && return 1
  version="${tag#v}"
  if $IS_MAC; then
    os="macOS"
    case "$(uname -m)" in x86_64) arch="64bit";; aarch64|arm64) arch="ARM64";; *) return 1;; esac
  else
    os="Linux"
    case "$(uname -m)" in x86_64) arch="64bit";; aarch64|arm64) arch="ARM64";; *) return 1;; esac
  fi
  mkdir -p "$dest"
  _stream_url "https://github.com/aquasecurity/trivy/releases/download/${tag}/trivy_${version}_${os}-${arch}.tar.gz" \
    | tar -xz -C "$dest" trivy 2>/dev/null
}

_install_tflint() {
  local tag version os arch dest="$HOME/.local/bin"
  tag=$(_latest_tag "terraform-linters/tflint") || return 1
  [[ -z "$tag" ]] && return 1
  version="${tag#v}"
  $IS_MAC && os="darwin" || os="linux"
  case "$(uname -m)" in x86_64) arch="amd64";; aarch64|arm64) arch="arm64";; *) return 1;; esac
  local tmp; tmp=$(mktemp -d)
  _download_file "https://github.com/terraform-linters/tflint/releases/download/${tag}/tflint_${os}_${arch}.zip" \
    "$tmp/tflint.zip" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$dest"
  if has unzip; then
    unzip -q "$tmp/tflint.zip" tflint -d "$dest" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  elif has python3; then
    python3 -c "import zipfile; zipfile.ZipFile('$tmp/tflint.zip').extract('tflint', '$dest')" \
      2>/dev/null || { rm -rf "$tmp"; return 1; }
  else
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  chmod +x "$dest/tflint"
}

_install_ansible_lint() {
  # apt package available on Ubuntu 22.04+ / Debian Bookworm.
  apt_install ansible-lint && return 0
  pip_install ansible-lint
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

  # Refresh apt package lists once before any installs so we get current versions.
  if [ "$install_missing" = "true" ] && has apt-get && has sudo; then
    info "Updating apt package lists..."
    sudo apt-get update -qq 2>/dev/null || true
  fi

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

  if has curl; then
    ok "curl"
  elif has wget; then
    ok "wget (curl absent — wget will be used for binary downloads)"
  else
    warn "curl / wget — neither found; binary tool installs will be skipped"
    warn "  Install with: sudo apt install curl"
  fi

  echo ""
  echo "── Code-level tools (/security-review) ───────────────────────────"

  _check_tool "semgrep"                    "Semgrep"                  "semgrep"      "semgrep"               ""                          "$install_missing"
  _check_tool "gitleaks"                   "gitleaks"                 "gitleaks"     ""                      ""                          "$install_missing"  "_install_gitleaks"
  _check_tool "njsscan"                    "njsscan"                  ""             "njsscan"               ""                          "$install_missing"
  _check_tool "retire"                     "retire.js"                ""             ""                      "retire"                    "$install_missing"
  _check_tool "htmlhint"                   "htmlhint"                 ""             ""                      "htmlhint"                  "$install_missing"
  _check_tool "license-checker-rseidelsohn" "license-checker"         ""             ""                      "license-checker-rseidelsohn" "$install_missing"
  _check_tool "scancode"                   "scancode-toolkit"         ""             "scancode-toolkit"      ""                          "$install_missing"

  echo ""
  echo "── Infrastructure tools (/arch-review) ────────────────────────────"

  _check_tool "checkov"                    "Checkov"                  "checkov"      "checkov"               ""                          "$install_missing"
  _check_tool "hadolint"                   "hadolint"                 "hadolint"     ""                      ""                          "$install_missing"  "_install_hadolint"
  _check_tool "trivy"                      "Trivy"                    "trivy"        ""                      ""                          "$install_missing"  "_install_trivy"
  _check_tool "tflint"                     "tflint"                   "tflint"       ""                      ""                          "$install_missing"  "_install_tflint"
  _check_tool "ansible-lint"               "ansible-lint"             ""             ""                      ""                          "$install_missing"  "_install_ansible_lint"

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
  local cmd="$1" label="$2" brew_pkg="$3" pip_pkg="$4" npm_pkg="$5" do_install="$6" custom_fn="${7:-}"

  if has "$cmd"; then
    ok "$label ($(command -v "$cmd"))"
    return 0
  fi

  if [ "$do_install" = "true" ]; then
    info "$label — not found, installing..."
    if try_install "$label" "$brew_pkg" "$pip_pkg" "$npm_pkg" "$custom_fn"; then
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

  local added_count
  added_count=$(python3 - "$settings_file" \
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
  )
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
