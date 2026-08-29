#!/bin/sh
#
# Run the complete phase-one proof against a clean registry.
#
# Resets the local registry and runs every stage in sequence.  A new run
# directory is created under artifacts/source-images/<run-id>/.
#
# Usage:  sh scripts/run-proof.sh [run-id]
#         make proof [RUN_ID=<id>]
#
# run-id may contain letters, digits, dots, underscores, and hyphens.
# If omitted a timestamp-based ID is generated automatically.

set -eu

run_id=${1:-}
if [ -z "$run_id" ]; then
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

case "$run_id" in
  *[!A-Za-z0-9._-]*)
    printf 'error: run ID may contain only letters, digits, dot, underscore, and hyphen\n' >&2
    exit 1
    ;;
esac

printf 'Phase-one proof  run-id: %s\n\n' "$run_id"

printf '── Tools ────────────────────────────────────────────────────────────────────\n'
sh scripts/tools-check.sh

printf '\n── Registry reset ───────────────────────────────────────────────────────────\n'
docker compose down --volumes --remove-orphans
docker compose up --detach --wait registry

printf '\n── Source images ────────────────────────────────────────────────────────────\n'
sh scripts/publish-source-images.sh "$run_id"

printf '\n── Source blobs ─────────────────────────────────────────────────────────────\n'
sh scripts/inventory-source-blobs.sh "$run_id"

printf '\n── Mount blobs ──────────────────────────────────────────────────────────────\n'
sh scripts/mount-source-blobs.sh "$run_id"

printf '\n── Synthetic manifest ───────────────────────────────────────────────────────\n'
sh scripts/generate-synthetic-manifest.sh "$run_id"

printf '\n── Publish synthetic ────────────────────────────────────────────────────────\n'
sh scripts/publish-synthetic-image.sh "$run_id"

printf '\n── Client matrix ────────────────────────────────────────────────────────────\n'
sh scripts/test-client-matrix.sh "$run_id"

printf '\n── Reconstruct payload ──────────────────────────────────────────────────────\n'
sh scripts/reconstruct-payload.sh "$run_id"

printf '\n── Phase-one report ─────────────────────────────────────────────────────────\n'
sh scripts/phase-one-report.sh "$run_id"

printf '\nProof complete  run-id: %s\n' "$run_id"
printf 'Evidence: artifacts/source-images/%s/\n' "$run_id"
printf 'Report:   artifacts/source-images/%s/phase-one-report.json\n' "$run_id"
