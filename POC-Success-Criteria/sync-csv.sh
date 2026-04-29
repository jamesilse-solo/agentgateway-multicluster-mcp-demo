#!/usr/bin/env bash
# Copies the Obsidian POC CSV into POC-Success-Criteria/, scrubbing
# any customer-identifying references before commit.
#
# Run manually after editing the CSV in Obsidian, or automatically via
# the Claude Code PostToolUse hook configured in .claude/settings.json.

set -euo pipefail

SRC="/Users/jamesilse/Documents/obsidian-soloio/singtel/_raw/POC CSV.md"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${REPO_ROOT}/POC-Success-Criteria/POC-Success-Criteria.md"

if [[ ! -f "${SRC}" ]]; then
  echo "sync-csv: source not found: ${SRC}" >&2
  exit 1
fi

sed \
  -e 's/cluster1-singtel/cluster1/g' \
  -e 's/cluster2-singtel/cluster2/g' \
  "${SRC}" > "${DEST}"

echo "sync-csv: updated ${DEST}"
