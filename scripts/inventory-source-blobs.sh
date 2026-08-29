#!/bin/sh
#
# Inventory and verify published source-image layer blobs (BLOB gate).
#
# For each source image from a completed source-images run, downloads every
# layer blob through the repository-scoped Distribution API, identifies the
# payload layer by inspecting tar contents (not by manifest position), and
# verifies descriptor digest, size, DiffID, and the extracted-part hash.
#
# Usage:  sh scripts/inventory-source-blobs.sh <run-id>
#         make source-blobs RUN_ID=<run-id>

set -eu

registry=${REGISTRY:-localhost:5000}
run_id=${1:?'run_id required; pass the run ID from a completed source-images run (make source-images RUN_ID=<id>)'}
source_dir="artifacts/source-images/$run_id"

if [ ! -f "$source_dir/report.json" ]; then
  printf 'error: source-images evidence not found at %s\n' "$source_dir/report.json" >&2
  printf 'Run "make source-images" and then pass its run ID.\n' >&2
  exit 1
fi

if ! curl --fail --silent --show-error "http://$registry/v2/" >/dev/null; then
  printf 'error: registry not reachable at %s; run make registry-up\n' "$registry" >&2
  exit 1
fi

payload_metadata="$source_dir/payload/metadata.json"
if [ ! -f "$payload_metadata" ]; then
  printf 'error: payload metadata not found at %s\n' "$payload_metadata" >&2
  exit 1
fi

temporary=$(mktemp -d "$source_dir/blob-verify.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

source_number=1
while [ "$source_number" -le 3 ]; do
  repository="poc/source-$source_number"
  part_index=$((source_number - 1))
  part_name=$(jq -r ".parts[$part_index].path" "$payload_metadata")
  expected_path="payload/archive.part$source_number"
  expected_part_digest=$(jq -r ".parts[$part_index].sha256" "$payload_metadata")
  manifest_digest=$(jq -r ".sources[$part_index].manifest_digest" "$source_dir/report.json")
  manifest_file="$source_dir/source-$source_number.manifest-by-digest.json"
  config_file="$source_dir/source-$source_number.config.json"
  layer_count=$(jq '.layers | length' "$manifest_file")

  printf 'source-%s: %s layers, manifest %s\n' "$source_number" "$layer_count" "$manifest_digest"

  base_digests="$temporary/s${source_number}-base-digests"
  : >"$base_digests"
  payload_found=0
  layer_index=0

  while [ "$layer_index" -lt "$layer_count" ]; do
    layer_digest=$(jq -r ".layers[$layer_index].digest" "$manifest_file")
    layer_size=$(jq -r ".layers[$layer_index].size" "$manifest_file")
    layer_media_type=$(jq -r ".layers[$layer_index].mediaType" "$manifest_file")
    layer_hex=${layer_digest#sha256:}

    head_headers="$source_dir/source-$source_number.layer-${layer_hex}.head.headers"
    get_headers="$source_dir/source-$source_number.layer-${layer_hex}.get.headers"
    blob_file="$temporary/${layer_hex}.tar.gz"
    tar_file="$temporary/${layer_hex}.tar"

    # HEAD: preserve response headers; verify Docker-Content-Digest when present.
    curl --fail --silent --show-error --head \
      --dump-header "$head_headers" \
      "http://$registry/v2/$repository/blobs/$layer_digest" \
      --output /dev/null
    head_dcd=$(grep -i '^Docker-Content-Digest:' "$head_headers" \
      | head -1 | tr -d '\r' | awk '{print $2}')
    if [ -n "$head_dcd" ] && [ "$head_dcd" != "$layer_digest" ]; then
      printf 'error: HEAD Docker-Content-Digest mismatch for %s: got %s\n' \
        "$layer_digest" "$head_dcd" >&2
      exit 1
    fi

    # GET: preserve response headers and blob bytes.
    curl --fail --silent --show-error \
      --dump-header "$get_headers" \
      "http://$registry/v2/$repository/blobs/$layer_digest" \
      --output "$blob_file"
    get_dcd=$(grep -i '^Docker-Content-Digest:' "$get_headers" \
      | head -1 | tr -d '\r' | awk '{print $2}')
    if [ -n "$get_dcd" ] && [ "$get_dcd" != "$layer_digest" ]; then
      printf 'error: GET Docker-Content-Digest mismatch for %s: got %s\n' \
        "$layer_digest" "$get_dcd" >&2
      exit 1
    fi

    # Response-body digest must equal the descriptor digest.
    body_digest="sha256:$(sha256sum "$blob_file" | awk '{print $1}')"
    if [ "$body_digest" != "$layer_digest" ]; then
      printf 'error: body digest mismatch: descriptor=%s body=%s\n' \
        "$layer_digest" "$body_digest" >&2
      exit 1
    fi

    # Downloaded byte count must equal the descriptor size.
    body_size=$(wc -c <"$blob_file" | tr -d '[:space:]')
    if [ "$body_size" != "$layer_size" ]; then
      printf 'error: body size mismatch: descriptor=%s body=%s\n' \
        "$layer_size" "$body_size" >&2
      exit 1
    fi

    # Decompress the exact response bytes; hash the tar stream as the DiffID.
    gzip -dc "$blob_file" >"$tar_file"
    diff_id="sha256:$(sha256sum "$tar_file" | awk '{print $1}')"

    # Verify the computed DiffID against the config's ordered diff_ids list.
    config_diff_id=$(jq -r ".rootfs.diff_ids[$layer_index]" "$config_file")
    if [ "$diff_id" != "$config_diff_id" ]; then
      printf 'error: DiffID mismatch at layer %s: config=%s computed=%s\n' \
        "$layer_index" "$config_diff_id" "$diff_id" >&2
      exit 1
    fi

    # Identify the payload layer by requiring the expected path to be its only
    # regular tar entry. Directory entries emitted by builders are ignored.
    regular_entries=$(tar -tf "$tar_file" \
      | awk 'substr($0, length($0), 1) != "/"')
    if [ "$regular_entries" = "$expected_path" ]; then

      # Verify the extracted part against the pre-OCI payload digest.
      extracted=$(tar -xOf "$tar_file" "$expected_path" | sha256sum | awk '{print $1}')
      if [ "$extracted" != "$expected_part_digest" ]; then
        printf 'error: extracted part digest mismatch: pre-oci=%s extracted=%s\n' \
          "$expected_part_digest" "$extracted" >&2
        exit 1
      fi

      payload_found=$((payload_found + 1))
      payload_digest=$layer_digest
      payload_size=$layer_size
      payload_media_type=$layer_media_type
      payload_diff_id=$diff_id
      payload_index=$layer_index
      printf '  [%s] payload: %s\n' "$layer_index" "$layer_digest"
    else
      printf '%s\n' "$layer_digest" >>"$base_digests"
      printf '  [%s] base:    %s\n' "$layer_index" "$layer_digest"
    fi

    layer_index=$((layer_index + 1))
  done

  if [ "$payload_found" -ne 1 ]; then
    printf 'error: expected exactly one layer containing only %s in source-%s, found %s\n' \
      "$expected_path" "$source_number" "$payload_found" >&2
    exit 1
  fi

  printf '%s\n' "$payload_digest" >>"$temporary/payload-digests"

  base_layers_json=$(jq -R . <"$base_digests" | jq -s .)

  jq --null-input \
    --arg source "source-$source_number" \
    --arg part_name "$part_name" \
    --arg repository "$repository" \
    --arg manifest_digest "$manifest_digest" \
    --arg payload_path "$expected_path" \
    --argjson payload_layer_index "$payload_index" \
    --arg digest "$payload_digest" \
    --argjson size "$payload_size" \
    --arg media_type "$payload_media_type" \
    --arg diff_id "$payload_diff_id" \
    --arg part_sha256 "$expected_part_digest" \
    --argjson base_layer_digests "$base_layers_json" \
    '{source: $source, part_name: $part_name, repository: $repository,
      image_digest: $manifest_digest, manifest_digest: $manifest_digest,
      identified_by: "tar-content-match", payload_layer_index: $payload_layer_index,
      payload_path: $payload_path,
      payload_layer: {digest: $digest, size: $size, mediaType: $media_type,
        diff_id: $diff_id},
      part_sha256: $part_sha256,
      base_layer_digests: $base_layer_digests}' \
    >"$source_dir/source-$source_number.blob-verify.json"

  source_number=$((source_number + 1))
done

if [ "$(sort -u "$temporary/payload-digests" | wc -l | tr -d '[:space:]')" -ne 3 ]; then
  printf 'error: selected payload-layer digests are not distinct\n' >&2
  exit 1
fi

jq --slurp --arg run_id "$run_id" --arg registry "$registry" \
  '{schema_version: 1, run_id: $run_id, registry: $registry, gate: "BLOB",
    blobs: .}' \
  "$source_dir/source-1.blob-verify.json" \
  "$source_dir/source-2.blob-verify.json" \
  "$source_dir/source-3.blob-verify.json" \
  >"$source_dir/blob-inventory.json"

printf '\nBlob inventory complete for run %s\n' "$run_id"
jq -r '.blobs[] | "  \(.source): payload=\(.payload_layer.digest) diff_id=\(.payload_layer.diff_id)"' \
  "$source_dir/blob-inventory.json"
printf 'Evidence: %s/blob-inventory.json\n' "$source_dir"
