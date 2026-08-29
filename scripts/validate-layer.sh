#!/bin/sh

set -eu

mkdir -p artifacts
temporary=$(mktemp -d artifacts/layer-validation.XXXXXX)
report=${1:-artifacts/layer-validation-report.json}
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

payload="$temporary/payload"
controlled_1="$temporary/controlled-1"
controlled_2="$temporary/controlled-2"
context="$temporary/context"
sh scripts/generate-payload.sh "$payload"
sh scripts/generate-layer.sh "$payload" "$controlled_1"
sh scripts/generate-layer.sh "$payload" "$controlled_2"

cmp "$controlled_1/layer.tar" "$controlled_2/layer.tar"
cmp "$controlled_1/layer.tar.gz" "$controlled_2/layer.tar.gz"
[ "$(tar -tf "$controlled_1/layer.tar")" = 'payload/archive.part1' ]
[ "$(tar -xOf "$controlled_1/layer.tar" payload/archive.part1 | sha256sum | awk '{print $1}')" = \
  "$(sha256sum "$payload/archive.part-01" | awk '{print $1}')" ]

recorded_digest=$(jq -r '.descriptor.digest' "$controlled_1/metadata.json")
recorded_size=$(jq -r '.descriptor.size' "$controlled_1/metadata.json")
recorded_diff_id=$(jq -r '.diff_id' "$controlled_1/metadata.json")
[ "$recorded_digest" = "sha256:$(sha256sum "$controlled_1/layer.tar.gz" | awk '{print $1}')" ]
[ "$recorded_size" = "$(wc -c <"$controlled_1/layer.tar.gz" | tr -d '[:space:]')" ]
gzip -dc "$controlled_1/layer.tar.gz" >"$temporary/downloaded.tar"
[ "$recorded_diff_id" = "sha256:$(sha256sum "$temporary/downloaded.tar" | awk '{print $1}')" ]
[ "$recorded_digest" != "$recorded_diff_id" ]

mkdir -p "$context"
cp fixtures/source-1/Dockerfile "$context/Dockerfile"
cp "$payload/archive.part-01" "$context/archive.part-01"

build_number=1
while [ "$build_number" -le 2 ]; do
  archive="$temporary/builder-$build_number.tar"
  root="$temporary/builder-$build_number"
  mkdir -p "$root"
  docker buildx build --no-cache --provenance=false \
    --output "type=oci,dest=$archive" "$context" >/dev/null
  tar -xf "$archive" -C "$root"
  index_digest=$(jq -r '.manifests[0].digest | sub("^sha256:"; "")' "$root/index.json")
  manifest="$root/blobs/sha256/$index_digest"
  layer_digest=$(jq -r '.layers[-1].digest' "$manifest")
  layer_size=$(jq -r '.layers[-1].size' "$manifest")
  layer_media_type=$(jq -r '.layers[-1].mediaType' "$manifest")
  layer_hex=${layer_digest#sha256:}
  layer_blob="$root/blobs/sha256/$layer_hex"
  [ "$layer_digest" = "sha256:$(sha256sum "$layer_blob" | awk '{print $1}')" ]
  [ "$layer_size" = "$(wc -c <"$layer_blob" | tr -d '[:space:]')" ]
  gzip -dc "$layer_blob" >"$temporary/builder-$build_number.layer.tar"
  [ "$(tar -tf "$temporary/builder-$build_number.layer.tar")" = \
    "payload/
payload/archive.part1" ]
  [ "$(tar -xOf "$temporary/builder-$build_number.layer.tar" payload/archive.part1 | sha256sum | awk '{print $1}')" = \
    "$(sha256sum "$payload/archive.part-01" | awk '{print $1}')" ]
  builder_diff_id="sha256:$(sha256sum "$temporary/builder-$build_number.layer.tar" | awk '{print $1}')"
  config_digest=$(jq -r '.config.digest | sub("^sha256:"; "")' "$manifest")
  [ "$builder_diff_id" = "$(jq -r '.rootfs.diff_ids[-1]' "$root/blobs/sha256/$config_digest")" ]
  jq --null-input --arg digest "$layer_digest" --argjson size "$layer_size" \
    --arg media_type "$layer_media_type" --arg diff_id "$builder_diff_id" \
    '{digest: $digest, size: $size, mediaType: $media_type, diff_id: $diff_id}' \
    >"$temporary/builder-$build_number.json"
  build_number=$((build_number + 1))
done

if cmp -s "$temporary/builder-1.json" "$temporary/builder-2.json"; then
  reproducible=true
  explanation='Two clean BuildKit exports produced the same final descriptor and DiffID.'
else
  reproducible=false
  explanation='BuildKit serialization differed; registry-exported source bytes and their measured descriptor are authoritative for reuse, which requires byte identity rather than equality with the hand-controlled tar.'
fi

if cmp -s "$controlled_1/layer.tar.gz" \
  "$temporary/builder-1/blobs/sha256/$(jq -r '.digest | sub("^sha256:"; "")' "$temporary/builder-1.json")"; then
  controlled_match=true
else
  controlled_match=false
fi

jq --null-input \
  --slurpfile controlled "$controlled_1/metadata.json" \
  --slurpfile builder "$temporary/builder-1.json" \
  --argjson builder_reproducible "$reproducible" \
  --argjson controlled_bytes_match_builder "$controlled_match" \
  --arg explanation "$explanation" \
  '{controlled: $controlled[0], builder: $builder[0], builder_reproducible: $builder_reproducible,
    controlled_bytes_match_builder: $controlled_bytes_match_builder,
    serialization_note: "BuildKit adds an explicit payload/ directory entry and context timestamps; the controlled tar contains only the normalized file entry.",
    authority_note: "The builder descriptor and DiffID are calculated from its exported OCI blob. Those exact bytes become authoritative when the source image is published.",
    reproducibility_note: $explanation}' >"$report"

printf 'Controlled descriptor: %s (%s bytes)\n' "$recorded_digest" "$recorded_size"
printf 'Controlled DiffID:     %s\n' "$recorded_diff_id"
printf 'Builder comparison: reproducible=%s controlled_bytes_match=%s\n' \
  "$reproducible" "$controlled_match"
jq . "$report"
printf 'Validation report: %s\n' "$report"
