#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_SRC="$SCRIPT_DIR/.claude/commands"
WORKFLOW_SRC="$SCRIPT_DIR/.github/workflows/security-scan.yml"

usage() {
  cat <<EOF
AI Security Reviewer — installer

Usage:
  install.sh --global                     Install skills to ~/.claude/commands/ (all projects)
  install.sh --project <path>             Install skills to <path>/.claude/commands/
  install.sh --ci <path>                  Copy CI workflow to <path>/.github/workflows/
  install.sh --all <path>                 Install skills + CI workflow to <path>

Examples:
  ./install.sh --global
  ./install.sh --project ~/work/my-app
  ./install.sh --all ~/work/my-app
  ./install.sh --ci ~/work/my-app

After installing, invoke skills in Claude Code with:
  /security-review    — npm/JS code-level review
  /arch-review        — infrastructure and IaC review
  /full-review        — both in parallel, unified report
EOF
  exit 1
}

install_skills() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$COMMANDS_SRC"/*.md "$dest/"
  echo "Skills installed to $dest"
  echo "  /security-review  /arch-review  /full-review"
}

install_ci() {
  local project="$1"
  local dest="$project/.github/workflows"
  mkdir -p "$dest"
  cp "$WORKFLOW_SRC" "$dest/security-scan.yml"
  echo "CI workflow installed to $dest/security-scan.yml"
  echo "  Commit it to your repo and it will run on every pull request."
  echo "  Optional: add SOCKET_API_KEY to your repo secrets for socket.dev scanning."
}

[[ $# -eq 0 ]] && usage

case "$1" in
  --global)
    install_skills "$HOME/.claude/commands"
    ;;
  --project)
    [[ -z "${2:-}" ]] && { echo "Error: --project requires a path"; usage; }
    install_skills "$2/.claude/commands"
    ;;
  --ci)
    [[ -z "${2:-}" ]] && { echo "Error: --ci requires a path"; usage; }
    install_ci "$2"
    ;;
  --all)
    [[ -z "${2:-}" ]] && { echo "Error: --all requires a path"; usage; }
    install_skills "$2/.claude/commands"
    install_ci "$2"
    ;;
  *)
    echo "Error: unknown option '$1'"
    usage
    ;;
esac
