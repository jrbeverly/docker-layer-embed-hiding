#!/bin/sh

set -eu

output_directory=${1:-artifacts/payload}
payload="$output_directory/payload.bin"
compressed="$output_directory/payload.bin.gz"
metadata="$output_directory/metadata.json"
part_1="$output_directory/archive.part-01"
part_2="$output_directory/archive.part-02"
part_3="$output_directory/archive.part-03"

block='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
block_bytes=64
repetitions=49152
expected_bytes=$((block_bytes * repetitions))

mkdir -p "$output_directory"
if [ -e "$payload" ] || [ -e "$compressed" ] || [ -e "$metadata" ] ||
  [ -e "$part_1" ] || [ -e "$part_2" ] || [ -e "$part_3" ]; then
  printf 'error: payload output already exists in %s\n' "$output_directory" >&2
  exit 1
fi

LC_ALL=C awk -v block="$block" -v repetitions="$repetitions" '
  BEGIN {
    for (i = 0; i < repetitions; i++) {
      printf "%s", block
    }
  }
' >"$payload"

actual_bytes=$(wc -c <"$payload" | tr -d '[:space:]')
if [ "$actual_bytes" -ne "$expected_bytes" ]; then
  printf 'error: expected %s payload bytes, generated %s\n' \
    "$expected_bytes" "$actual_bytes" >&2
  exit 1
fi

digest=$(sha256sum "$payload" | awk '{print $1}')

gzip -n -c "$payload" >"$compressed"
split --number=3 --numeric-suffixes=1 --suffix-length=2 \
  "$compressed" "$output_directory/archive.part-"

for part in "$part_1" "$part_2" "$part_3"; do
  if [ ! -s "$part" ]; then
    printf 'error: expected non-empty archive piece %s\n' "$part" >&2
    exit 1
  fi
done

compressed_bytes=$(wc -c <"$compressed" | tr -d '[:space:]')
compressed_digest=$(sha256sum "$compressed" | awk '{print $1}')
part_1_bytes=$(wc -c <"$part_1" | tr -d '[:space:]')
part_2_bytes=$(wc -c <"$part_2" | tr -d '[:space:]')
part_3_bytes=$(wc -c <"$part_3" | tr -d '[:space:]')
part_1_digest=$(sha256sum "$part_1" | awk '{print $1}')
part_2_digest=$(sha256sum "$part_2" | awk '{print $1}')
part_3_digest=$(sha256sum "$part_3" | awk '{print $1}')

jq --null-input \
  --arg algorithm 'repeated-ascii-block-v1' \
  --arg block "$block" \
  --arg sha256 "$digest" \
  --arg compressed_sha256 "$compressed_digest" \
  --arg part_1_sha256 "$part_1_digest" \
  --arg part_2_sha256 "$part_2_digest" \
  --arg part_3_sha256 "$part_3_digest" \
  --argjson block_bytes "$block_bytes" \
  --argjson repetitions "$repetitions" \
  --argjson byte_count "$actual_bytes" \
  --argjson compressed_byte_count "$compressed_bytes" \
  --argjson part_1_byte_count "$part_1_bytes" \
  --argjson part_2_byte_count "$part_2_bytes" \
  --argjson part_3_byte_count "$part_3_bytes" \
  '{
    schema_version: 1,
    payload: {
      path: "payload.bin",
      byte_count: $byte_count,
      sha256: $sha256
    },
    compressed: {
      path: "payload.bin.gz",
      byte_count: $compressed_byte_count,
      sha256: $compressed_sha256,
      gzip_options: ["-n"]
    },
    parts: [
      {path: "archive.part-01", byte_count: $part_1_byte_count, sha256: $part_1_sha256},
      {path: "archive.part-02", byte_count: $part_2_byte_count, sha256: $part_2_sha256},
      {path: "archive.part-03", byte_count: $part_3_byte_count, sha256: $part_3_sha256}
    ],
    generator: {
      algorithm: $algorithm,
      block: $block,
      block_bytes: $block_bytes,
      repetitions: $repetitions
    },
    commands: {
      payload: "LC_ALL=C awk (repeated-ascii-block-v1) > payload.bin",
      compress: "gzip -n -c payload.bin > payload.bin.gz",
      split: "split --number=3 --numeric-suffixes=1 --suffix-length=2 payload.bin.gz archive.part-",
      reconstruct: "cat archive.part-01 archive.part-02 archive.part-03 > reconstructed.gz"
    }
  }' >"$metadata"

printf 'Generated %s bytes at %s (sha256:%s)\n' \
  "$actual_bytes" "$payload" "$digest"
printf 'Compressed to %s bytes and split into archive.part-{01,02,03} (sha256:%s)\n' \
  "$compressed_bytes" "$compressed_digest"
