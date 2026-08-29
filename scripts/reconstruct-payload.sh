#!/bin/sh
#
# Reconstruct the original payload from the synthetic image layers and verify
# its SHA-256 matches the pre-OCI original (RECONSTRUCTION gate).
#
# Reads the three layer blobs saved by test-client-matrix.sh:
#   matrix-api-layer-{1,2,3}.tar.gz
#
# For each layer, decompresses the gzip stream, extracts the payload part file
# from the tar, and concatenates the three parts in order.  The concatenated
# result is the split-reassembled gzip stream; decompressing it yields
# payload.bin whose SHA-256 must equal the value recorded in
# artifacts/source-images/<run-id>/payload/metadata.json.
#
# Evidence produced (all in artifacts/source-images/<run-id>/):
#   reconstruction-gate.json
#
# Usage:  sh scripts/reconstruct-payload.sh <run-id>
#         make reconstruct RUN_ID=<run-id>

set -eu

run_id=${1:?'run_id required; pass the run ID from a completed client-matrix run'}
source_dir="artifacts/source-images/$run_id"

# ── Prerequisite checks ──────────────────────────────────────────────────────

for prereq in client-matrix-gate.json blob-inventory.json; do
  if [ ! -f "$source_dir/$prereq" ]; then
    printf 'error: %s not found; run make client-matrix RUN_ID=%s first\n' \
      "$prereq" "$run_id" >&2
    exit 1
  fi
done

payload_metadata="$source_dir/payload/metadata.json"
if [ ! -f "$payload_metadata" ]; then
  printf 'error: payload metadata not found at %s\n' "$payload_metadata" >&2
  exit 1
fi

for n in 1 2 3; do
  layer_blob="$source_dir/matrix-api-layer-${n}.tar.gz"
  if [ ! -f "$layer_blob" ]; then
    printf 'error: layer blob not found: %s\n' "$layer_blob" >&2
    printf 'Run "make client-matrix RUN_ID=%s" first.\n' "$run_id" >&2
    exit 1
  fi
done

if [ -f "$source_dir/reconstruction-gate.json" ]; then
  printf 'error: reconstruction-gate.json already exists at %s\n' "$source_dir" >&2
  exit 1
fi

original_payload_sha256=$(jq -r '.payload.sha256' "$payload_metadata")
original_payload_bytes=$(jq -r '.payload.byte_count' "$payload_metadata")
original_compressed_sha256=$(jq -r '.compressed.sha256' "$payload_metadata")
original_compressed_bytes=$(jq -r '.compressed.byte_count' "$payload_metadata")

printf 'Original payload SHA-256: %s\n' "$original_payload_sha256"
printf 'Original payload bytes:   %s\n' "$original_payload_bytes"

temporary=$(mktemp -d "$source_dir/reconstruct-work.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# ── Extract each part from its layer tar ────────────────────────────────────

printf '\nExtracting payload parts from layer tars...\n'

for n in 1 2 3; do
  layer_blob="$source_dir/matrix-api-layer-${n}.tar.gz"
  part_path="payload/archive.part${n}"
  part_file="$temporary/archive.part${n}"
  expected_part_sha256=$(jq -r ".blobs[$((n - 1))].part_sha256" \
    "$source_dir/blob-inventory.json")

  layer_digest=$(jq -r ".blobs[$((n - 1))].payload_layer.digest" \
    "$source_dir/blob-inventory.json")
  layer_size=$(jq -r ".blobs[$((n - 1))].payload_layer.size" \
    "$source_dir/blob-inventory.json")

  # Verify the stored blob still matches its descriptor before inspecting or
  # extracting anything from it.
  stored_digest="sha256:$(sha256sum "$layer_blob" | awk '{print $1}')"
  stored_size=$(wc -c < "$layer_blob" | tr -d '[:space:]')
  if [ "$stored_digest" != "$layer_digest" ]; then
    printf 'error: layer %s blob digest changed since download: expected=%s got=%s\n' \
      "$n" "$layer_digest" "$stored_digest" >&2
    exit 1
  fi
  if [ "$stored_size" != "$layer_size" ]; then
    printf 'error: layer %s blob size changed since download: expected=%s got=%s\n' \
      "$n" "$layer_size" "$stored_size" >&2
    exit 1
  fi

  layer_tar="$temporary/layer-${n}.tar"
  gzip -dc "$layer_blob" > "$layer_tar"
  payload_files=$(tar -tf "$layer_tar" | awk '! /\/$/ { print }')
  if [ "$payload_files" != "$part_path" ]; then
    printf 'error: layer %s payload view must contain only %s; found:\n%s\n' \
      "$n" "$part_path" "$payload_files" >&2
    exit 1
  fi

  tar -xOf "$layer_tar" "$part_path" > "$part_file"

  extracted_sha256=$(sha256sum "$part_file" | awk '{print $1}')
  if [ "$extracted_sha256" != "$expected_part_sha256" ]; then
    printf 'error: part %s sha256 mismatch: expected=%s extracted=%s\n' \
      "$n" "$expected_part_sha256" "$extracted_sha256" >&2
    exit 1
  fi

  part_bytes=$(wc -c < "$part_file" | tr -d '[:space:]')
  printf '  part %s: %s bytes  sha256=%s  OK\n' "$n" "$part_bytes" "$extracted_sha256"
done

# ── Reassemble and decompress ────────────────────────────────────────────────

validate_parts() {
  _parts_dir=$1

  set -- "$_parts_dir"/archive.part*
  [ "$#" -eq 3 ] || return 1

  _n=1
  while [ "$_n" -le 3 ]; do
    _part="$_parts_dir/archive.part$_n"
    [ -f "$_part" ] || return 1
    _expected_sha256=$(jq -r ".blobs[$((_n - 1))].part_sha256" \
      "$source_dir/blob-inventory.json")
    [ "$(sha256sum "$_part" | awk '{print $1}')" = "$_expected_sha256" ] || return 1
    _n=$((_n + 1))
  done

  cat "$_parts_dir/archive.part1" "$_parts_dir/archive.part2" \
    "$_parts_dir/archive.part3" > "$_parts_dir/validated.gz"
  [ "$(wc -c < "$_parts_dir/validated.gz" | tr -d '[:space:]')" = \
    "$original_compressed_bytes" ] || return 1
  [ "$(sha256sum "$_parts_dir/validated.gz" | awk '{print $1}')" = \
    "$original_compressed_sha256" ] || return 1
}

if ! validate_parts "$temporary"; then
  printf 'error: extracted payload view failed validation\n' >&2
  exit 1
fi

printf '\nExercising invalid payload-piece cases...\n'
for scenario in missing changed duplicated reordered; do
  fixture="$temporary/invalid-$scenario"
  mkdir -p "$fixture"
  cp "$temporary/archive.part1" "$temporary/archive.part2" \
    "$temporary/archive.part3" "$fixture/"
  case "$scenario" in
    missing)
      rm "$fixture/archive.part2"
      ;;
    changed)
      printf 'changed' >> "$fixture/archive.part2"
      ;;
    duplicated)
      cp "$fixture/archive.part1" "$fixture/archive.part2"
      ;;
    reordered)
      mv "$fixture/archive.part1" "$fixture/archive.swap"
      mv "$fixture/archive.part3" "$fixture/archive.part1"
      mv "$fixture/archive.swap" "$fixture/archive.part3"
      ;;
  esac
  if validate_parts "$fixture" 2>/dev/null; then
    printf 'error: %s payload pieces unexpectedly passed validation\n' \
      "$scenario" >&2
    exit 1
  fi
  printf '  %s: detected\n' "$scenario"
done

printf '\nReassembling parts into compressed archive...\n'

reassembled_gz="$temporary/reassembled.gz"
cp "$temporary/validated.gz" "$reassembled_gz"

reassembled_gz_bytes=$(wc -c < "$reassembled_gz" | tr -d '[:space:]')
printf '  reassembled gz: %s bytes\n' "$reassembled_gz_bytes"

printf 'Decompressing reassembled archive...\n'

reconstructed_bin="$temporary/reconstructed.bin"
gzip -dc "$reassembled_gz" > "$reconstructed_bin"

reconstructed_bytes=$(wc -c < "$reconstructed_bin" | tr -d '[:space:]')
reconstructed_sha256=$(sha256sum "$reconstructed_bin" | awk '{print $1}')

printf '  reconstructed payload.bin: %s bytes\n' "$reconstructed_bytes"
printf '  reconstructed SHA-256:     %s\n' "$reconstructed_sha256"

# ── Verify ───────────────────────────────────────────────────────────────────

sha256_match=false
bytes_match=false

if [ "$reconstructed_sha256" = "$original_payload_sha256" ]; then
  sha256_match=true
  printf '\nSHA-256 MATCH: reconstructed payload equals original\n'
else
  printf '\nerror: SHA-256 MISMATCH\n' >&2
  printf '  original:      %s\n' "$original_payload_sha256" >&2
  printf '  reconstructed: %s\n' "$reconstructed_sha256" >&2
  exit 1
fi

if [ "$reconstructed_bytes" = "$original_payload_bytes" ]; then
  bytes_match=true
  printf 'Byte count MATCH: %s bytes\n' "$reconstructed_bytes"
else
  printf 'error: byte count mismatch: original=%s reconstructed=%s\n' \
    "$original_payload_bytes" "$reconstructed_bytes" >&2
  exit 1
fi

# ── Reconstruction gate evidence ─────────────────────────────────────────────

jq --null-input \
  --arg  run_id                   "$run_id" \
  --arg  original_sha256          "$original_payload_sha256" \
  --argjson original_bytes        "$original_payload_bytes" \
  --arg  reconstructed_sha256     "$reconstructed_sha256" \
  --argjson reconstructed_bytes   "$reconstructed_bytes" \
  --argjson reassembled_gz_bytes  "$reassembled_gz_bytes" \
  --argjson sha256_match          "$sha256_match" \
  --argjson bytes_match           "$bytes_match" \
  '{schema_version: 1,
    run_id: $run_id,
    gate: "RECONSTRUCTION",
    source_layer_blobs: [
      "matrix-api-layer-1.tar.gz",
      "matrix-api-layer-2.tar.gz",
      "matrix-api-layer-3.tar.gz"
    ],
    extraction: {
      part_paths_in_layer_tar: [
        "payload/archive.part1",
        "payload/archive.part2",
        "payload/archive.part3"
      ],
      exact_payload_paths_verified: true,
      all_part_sha256_verified: true,
      invalid_piece_tests: {
        missing_detected: true,
        changed_detected: true,
        duplicated_detected: true,
        reordered_detected: true
      }
    },
    reassembly: {
      method: "cat part1 part2 part3 | gzip -dc",
      reassembled_gz_bytes: $reassembled_gz_bytes
    },
    verification: {
      original_payload_sha256: $original_sha256,
      original_payload_bytes: $original_bytes,
      reconstructed_payload_sha256: $reconstructed_sha256,
      reconstructed_payload_bytes: $reconstructed_bytes,
      sha256_match: $sha256_match,
      bytes_match: $bytes_match
    }}' \
  > "$source_dir/reconstruction-gate.json"

printf '\nRECONSTRUCTION gate complete for run %s.\n' "$run_id"
printf 'Evidence: %s/reconstruction-gate.json\n' "$source_dir"
