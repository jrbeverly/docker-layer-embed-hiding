#!/bin/sh

set -eu

validate_payload_directory() {
  run=$1
  metadata="$run/metadata.json"

  [ -f "$run/payload.bin" ]
  [ -f "$run/payload.bin.gz" ]
  [ -f "$metadata" ]

  measured_bytes=$(wc -c <"$run/payload.bin" | tr -d '[:space:]')
  measured_digest=$(sha256sum "$run/payload.bin" | awk '{print $1}')
  recorded_bytes=$(jq -r '.payload.byte_count' "$metadata")
  recorded_digest=$(jq -r '.payload.sha256' "$metadata")
  [ "$measured_bytes" = "$recorded_bytes" ]
  [ "$measured_digest" = "$recorded_digest" ]

  set -- "$run"/archive.part-*
  [ "$#" -eq 3 ]
  part_index=0
  for part in "$run/archive.part-01" "$run/archive.part-02" "$run/archive.part-03"; do
    [ -s "$part" ]
    recorded_part_path=$(jq -r ".parts[$part_index].path" "$metadata")
    recorded_part_bytes=$(jq -r ".parts[$part_index].byte_count" "$metadata")
    recorded_part_digest=$(jq -r ".parts[$part_index].sha256" "$metadata")
    [ "$recorded_part_path" = "${part##*/}" ]
    [ "$recorded_part_bytes" = "$(wc -c <"$part" | tr -d '[:space:]')" ]
    [ "$recorded_part_digest" = "$(sha256sum "$part" | awk '{print $1}')" ]
    part_index=$((part_index + 1))
  done

  reconstructed="$run/reconstructed.gz"
  cat "$run/archive.part-01" "$run/archive.part-02" \
    "$run/archive.part-03" >"$reconstructed"
  compressed_bytes=$(wc -c <"$run/payload.bin.gz" | tr -d '[:space:]')
  compressed_digest=$(sha256sum "$run/payload.bin.gz" | awk '{print $1}')
  recorded_compressed_bytes=$(jq -r '.compressed.byte_count' "$metadata")
  recorded_compressed_digest=$(jq -r '.compressed.sha256' "$metadata")
  [ "$compressed_bytes" = "$recorded_compressed_bytes" ]
  [ "$compressed_digest" = "$recorded_compressed_digest" ]
  [ "$(sha256sum "$reconstructed" | awk '{print $1}')" = "$compressed_digest" ]

  recovered="$run/recovered.bin"
  gzip -dc "$reconstructed" >"$recovered"
  [ "$(wc -c <"$recovered" | tr -d '[:space:]')" = "$measured_bytes" ]
  [ "$(sha256sum "$recovered" | awk '{print $1}')" = "$measured_digest" ]
}

if [ "$#" -gt 0 ]; then
  validate_payload_directory "$1"
  exit 0
fi

mkdir -p artifacts
temporary=$(mktemp -d artifacts/payload-validation.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

first="$temporary/first"
second="$temporary/second"
sh scripts/generate-payload.sh "$first"
sh scripts/generate-payload.sh "$second"

cmp "$first/payload.bin" "$second/payload.bin"
cmp "$first/payload.bin.gz" "$second/payload.bin.gz"
for name in archive.part-01 archive.part-02 archive.part-03; do
  cmp "$first/$name" "$second/$name"
done

for run in "$first" "$second"; do
  validate_payload_directory "$run"
done

first_digest=$(jq -r '.payload.sha256' "$first/metadata.json")
second_digest=$(jq -r '.payload.sha256' "$second/metadata.json")
[ "$first_digest" = "$second_digest" ]

first_compressed_digest=$(jq -r '.compressed.sha256' "$first/metadata.json")
second_compressed_digest=$(jq -r '.compressed.sha256' "$second/metadata.json")
[ "$first_compressed_digest" = "$second_compressed_digest" ]
[ "$(jq -c '.parts' "$first/metadata.json")" = \
  "$(jq -c '.parts' "$second/metadata.json")" ]

for scenario in missing changed reordered; do
  fixture="$temporary/$scenario"
  cp -R "$first" "$fixture"
  case "$scenario" in
    missing)
      rm "$fixture/archive.part-02"
      ;;
    changed)
      printf 'changed' >>"$fixture/archive.part-02"
      ;;
    reordered)
      mv "$fixture/archive.part-01" "$fixture/archive.part-swap"
      mv "$fixture/archive.part-02" "$fixture/archive.part-01"
      mv "$fixture/archive.part-swap" "$fixture/archive.part-02"
      ;;
  esac
  if sh "$0" "$fixture" >/dev/null 2>&1; then
    printf 'error: %s parts unexpectedly passed validation\n' "$scenario" >&2
    exit 1
  fi
done

printf 'Payload compression and reconstruction validated: %s bytes, sha256:%s\n' \
  "$(jq -r '.payload.byte_count' "$first/metadata.json")" "$first_digest"
