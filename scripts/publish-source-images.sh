#!/bin/sh

set -eu

registry=${REGISTRY:-localhost:5000}
run_id=${1:-"$(date -u +%Y%m%dT%H%M%SZ)-$$"}
output_directory=${2:-"artifacts/source-images/$run_id"}
manifest_media_types='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

case "$run_id" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'error: run ID may contain only letters, digits, dot, underscore, and hyphen\n' >&2
    exit 1
    ;;
esac

if [ -e "$output_directory" ]; then
  printf 'error: source-image evidence already exists at %s\n' "$output_directory" >&2
  exit 1
fi

mkdir -p "$output_directory"
temporary=$(mktemp -d artifacts/source-images-build.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

if ! curl --fail --silent --show-error "http://$registry/v2/" >/dev/null; then
  printf 'error: registry is not reachable at %s; run make registry-up\n' "$registry" >&2
  exit 1
fi

sh scripts/generate-payload.sh "$output_directory/payload"

source_number=1
while [ "$source_number" -le 3 ]; do
  repository="poc/source-$source_number"
  tag="run-$run_id"
  reference="$registry/$repository:$tag"
  manifest_url="http://$registry/v2/$repository/manifests/$tag"
  existing_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Accept: $manifest_media_types" "$manifest_url")
  if [ "$existing_status" != 404 ]; then
    printf 'error: refusing to overwrite %s (registry returned HTTP %s)\n' \
      "$reference" "$existing_status" >&2
    exit 1
  fi

  context="$temporary/source-$source_number"
  mkdir -p "$context"
  cp "fixtures/source-$source_number/Dockerfile" "$context/Dockerfile"
  cp "$output_directory/payload/archive.part-0$source_number" "$context/archive.part-0$source_number"

  docker buildx build --platform linux/amd64 --no-cache --provenance=false --sbom=false \
    --push --tag "$reference" --metadata-file "$output_directory/source-$source_number.build.json" \
    "$context" >"$output_directory/source-$source_number.build.log" 2>&1

  manifest_by_tag="$output_directory/source-$source_number.manifest.json"
  curl --fail --silent --show-error --dump-header "$output_directory/source-$source_number.manifest-by-tag.headers" \
    --header "Accept: $manifest_media_types" "$manifest_url" --output "$manifest_by_tag"
  jq -e '.schemaVersion == 2 and (.layers | length) >= 1' "$manifest_by_tag" >/dev/null

  manifest_hex=$(sha256sum "$manifest_by_tag" | awk '{print $1}')
  manifest_digest="sha256:$manifest_hex"
  manifest_by_digest="$output_directory/source-$source_number.manifest-by-digest.json"
  curl --fail --silent --show-error --dump-header "$output_directory/source-$source_number.manifest-by-digest.headers" \
    --header "Accept: $manifest_media_types" \
    "http://$registry/v2/$repository/manifests/$manifest_digest" --output "$manifest_by_digest"
  cmp "$manifest_by_tag" "$manifest_by_digest"

  expected_path="payload/archive.part$source_number"
  config_digest=$(jq -r '.config.digest' "$manifest_by_tag")
  config="$output_directory/source-$source_number.config.json"
  curl --fail --silent --show-error --dump-header "$output_directory/source-$source_number.config.headers" \
    "http://$registry/v2/$repository/blobs/$config_digest" --output "$config"
  [ "$(jq -r '.architecture + "/" + .os' "$config")" = 'amd64/linux' ]
  [ "$(jq '.rootfs.diff_ids | length' "$config")" = "$(jq '.layers | length' "$manifest_by_tag")" ]

  # Locate the payload layer by inspecting every distributed blob. Instruction
  # order is not evidence that the final manifest entry is the payload layer.
  expected_part_digest=$(sha256sum \
    "$output_directory/payload/archive.part-0$source_number" | awk '{print $1}')
  layer_count=$(jq '.layers | length' "$manifest_by_tag")
  candidate_index=0
  selected_index=''
  matches=0
  while [ "$candidate_index" -lt "$layer_count" ]; do
    candidate_digest=$(jq -r ".layers[$candidate_index].digest" "$manifest_by_tag")
    candidate_blob="$temporary/source-$source_number.candidate-$candidate_index.blob"
    candidate_headers="$temporary/source-$source_number.candidate-$candidate_index.headers"
    candidate_tar="$temporary/source-$source_number.candidate-$candidate_index.tar"
    curl --fail --silent --show-error --dump-header "$candidate_headers" \
      "http://$registry/v2/$repository/blobs/$candidate_digest" --output "$candidate_blob"

    if gzip -dc "$candidate_blob" >"$candidate_tar" 2>/dev/null &&
      [ "$(tar -tf "$candidate_tar" 2>/dev/null | awk 'substr($0, length($0), 1) != "/"')" = "$expected_path" ] &&
      [ "$(tar -xOf "$candidate_tar" "$expected_path" 2>/dev/null | sha256sum | awk '{print $1}')" = "$expected_part_digest" ]; then
      matches=$((matches + 1))
      selected_index=$candidate_index
      cp "$candidate_blob" "$output_directory/source-$source_number.payload-layer.tar.gz"
      cp "$candidate_headers" "$output_directory/source-$source_number.payload-layer.headers"
      cp "$candidate_tar" "$temporary/source-$source_number.payload-layer.tar"
    fi
    candidate_index=$((candidate_index + 1))
  done
  if [ "$matches" -ne 1 ]; then
    printf 'error: expected exactly one payload layer in %s, found %s\n' \
      "$reference" "$matches" >&2
    exit 1
  fi

  selected_digest=$(jq -r ".layers[$selected_index].digest" "$manifest_by_tag")
  selected_size=$(jq -r ".layers[$selected_index].size" "$manifest_by_tag")
  selected_media_type=$(jq -r ".layers[$selected_index].mediaType" "$manifest_by_tag")
  blob="$output_directory/source-$source_number.payload-layer.tar.gz"
  layer_tar="$temporary/source-$source_number.payload-layer.tar"
  [ "$selected_digest" = "sha256:$(sha256sum "$blob" | awk '{print $1}')" ]
  [ "$selected_size" = "$(wc -c <"$blob" | tr -d '[:space:]')" ]
  tar -tf "$layer_tar" >"$output_directory/source-$source_number.payload-layer.entries"
  diff_id="sha256:$(sha256sum "$layer_tar" | awk '{print $1}')"
  [ "$(jq -r ".rootfs.diff_ids[$selected_index]" "$config")" = "$diff_id" ]

  jq --null-input \
    --arg source "source-$source_number" --arg image "$reference" --arg tag "$tag" \
    --arg manifest_digest "$manifest_digest" --arg payload_path "$expected_path" \
    --argjson selected_index "$selected_index" \
    --arg selected_digest "$selected_digest" --argjson selected_size "$selected_size" \
    --arg selected_media_type "$selected_media_type" --arg diff_id "$diff_id" \
    --slurpfile manifest "$manifest_by_tag" \
    '{source: $source, image: $image, tag: $tag, platform: "linux/amd64",
      manifest_digest: $manifest_digest, payload_path: $payload_path,
      selection: {method: "download-and-inspect", manifest_index: $selected_index},
      selected_layer: {digest: $selected_digest, size: $selected_size,
        mediaType: $selected_media_type, diff_id: $diff_id},
      base_layers: [$manifest[0].layers | to_entries[] |
        select(.key != $selected_index) | .value]}' \
    >"$output_directory/source-$source_number.json"

  printf '%s\n' "$selected_digest" >>"$temporary/selected-digests"
  source_number=$((source_number + 1))
done

[ "$(sort -u "$temporary/selected-digests" | wc -l | tr -d '[:space:]')" -eq 3 ]

jq --slurp --arg run_id "$run_id" --arg registry "$registry" \
  '{schema_version: 1, run_id: $run_id, registry: $registry, sources: .}' \
  "$output_directory/source-1.json" "$output_directory/source-2.json" \
  "$output_directory/source-3.json" >"$output_directory/report.json"

printf 'Published and validated source images for run %s:\n' "$run_id"
jq -r '.sources[] | "  \(.image) @ \(.manifest_digest) payload=\(.selected_layer.digest)"' \
  "$output_directory/report.json"
printf 'Evidence: %s\n' "$output_directory"
