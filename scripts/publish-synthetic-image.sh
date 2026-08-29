#!/bin/sh
#
# Publish the synthetic OCI image through the Distribution API (MANIFEST gate).
#
# Uploads only the synthetic config blob to poc/synthetic, then PUTs the
# synthetic manifest under a run-tagged reference.  The three payload layer
# blobs are already present via the cross-repository mounts performed by
# mount-source-blobs.sh; this script uploads no layer content.
#
# After publishing, validates:
#   1. Config upload PUT accepted; returned Docker-Content-Digest matches local.
#   2. Manifest PUT accepted; returned Docker-Content-Digest matches local.
#   3. Config and manifest fetched by digest are byte-identical to local files.
#   4. All three payload layer HEAD and GET requests succeed under poc/synthetic.
#   5. A negative manifest referencing a nonexistent layer is rejected or,
#      if accepted by this registry, documented with a subsequent blob HEAD.
#
# Usage:  sh scripts/publish-synthetic-image.sh <run-id>
#         make publish-synthetic RUN_ID=<run-id>

set -eu

registry=${REGISTRY:-localhost:5000}
run_id=${1:?'run_id required; pass the run ID from a completed synthetic-manifest run'}
source_dir="artifacts/source-images/$run_id"
synthetic_repo="poc/synthetic"
synthetic_tag="run-$run_id"

# ── Prerequisite checks ──────────────────────────────────────────────────────

for prereq in blob-inventory.json visibility.json synthetic-config.json synthetic-manifest.json; do
  if [ ! -f "$source_dir/$prereq" ]; then
    printf 'error: %s not found at %s\n' "$prereq" "$source_dir/$prereq" >&2
    printf 'Run "make synthetic-manifest RUN_ID=%s" first.\n' "$run_id" >&2
    exit 1
  fi
done

if [ -f "$source_dir/publish-gate.json" ]; then
  printf 'error: publish-gate.json already exists at %s\n' "$source_dir" >&2
  exit 1
fi

if ! curl --fail --silent --show-error "http://$registry/v2/" >/dev/null; then
  printf 'error: registry not reachable at %s; run make registry-up\n' "$registry" >&2
  exit 1
fi

existing_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://$registry/v2/$synthetic_repo/manifests/$synthetic_tag")
if [ "$existing_status" != "404" ]; then
  printf 'error: %s:%s already exists in the registry (status %s)\n' \
    "$synthetic_repo" "$synthetic_tag" "$existing_status" >&2
  printf 'Run "make registry-reset" to start with a clean registry.\n' >&2
  exit 1
fi

config_file="$source_dir/synthetic-config.json"
manifest_file="$source_dir/synthetic-manifest.json"

config_digest="sha256:$(sha256sum "$config_file" | awk '{print $1}')"
config_size=$(wc -c < "$config_file" | tr -d '[:space:]')
manifest_digest="sha256:$(sha256sum "$manifest_file" | awk '{print $1}')"
manifest_size=$(wc -c < "$manifest_file" | tr -d '[:space:]')
manifest_media_type=$(jq -r '.mediaType' "$manifest_file")

printf 'Config:   %s  size=%s\n' "$config_digest" "$config_size"
printf 'Manifest: %s  size=%s\n' "$manifest_digest" "$manifest_size"

temporary=$(mktemp -d "$source_dir/publish-work.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# ── 1. Upload config blob ────────────────────────────────────────────────────

printf '\nUploading config blob to %s...\n' "$synthetic_repo"

upload_init_headers="$source_dir/publish-config-init.headers"
upload_init_body="$source_dir/publish-config-init.body"
upload_init_trace="$source_dir/publish-config-init.trace"
upload_init_status=$(curl --silent --show-error \
  --request POST \
  --dump-header "$upload_init_headers" \
  --trace-ascii "$upload_init_trace" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/blobs/uploads/" \
  --output "$upload_init_body")

if [ "$upload_init_status" != "202" ]; then
  printf 'error: blob upload initiation returned %s (expected 202)\n' \
    "$upload_init_status" >&2
  exit 1
fi

upload_location=$(grep -i '^Location:' "$upload_init_headers" \
  | head -1 | tr -d '\r' | awk '{print $2}')
if [ -z "$upload_location" ]; then
  printf 'error: no Location header in upload initiation response\n' >&2
  exit 1
fi

case "$upload_location" in
  http://*|https://*) upload_base="$upload_location" ;;
  *) upload_base="http://$registry$upload_location" ;;
esac

case "$upload_base" in
  *'?'*) config_put_url="${upload_base}&digest=${config_digest}" ;;
  *)     config_put_url="${upload_base}?digest=${config_digest}" ;;
esac

config_put_headers="$source_dir/publish-config-put.headers"
config_put_body="$source_dir/publish-config-put.body"
config_put_trace="$source_dir/publish-config-put.trace"
config_put_status=$(curl --silent --show-error \
  --request PUT \
  --header 'Content-Type: application/octet-stream' \
  --data-binary "@$config_file" \
  --dump-header "$config_put_headers" \
  --trace-ascii "$config_put_trace" \
  --write-out '%{http_code}' \
  "$config_put_url" \
  --output "$config_put_body")

if [ "$config_put_status" != "201" ]; then
  printf 'error: config blob PUT returned %s (expected 201)\n' "$config_put_status" >&2
  exit 1
fi

config_put_dcd=$(grep -i '^Docker-Content-Digest:' "$config_put_headers" \
  | head -1 | tr -d '\r' | awk '{print $2}')
if [ "$config_put_dcd" != "$config_digest" ]; then
  printf 'error: config PUT Docker-Content-Digest mismatch: got %s expected %s\n' \
    "$config_put_dcd" "$config_digest" >&2
  exit 1
fi
printf '  config upload: %s  dcd=%s\n' "$config_put_status" "${config_put_dcd:-none}"

# ── 2. PUT synthetic manifest ────────────────────────────────────────────────

printf '\nPublishing synthetic manifest as %s:%s...\n' "$synthetic_repo" "$synthetic_tag"

manifest_put_headers="$source_dir/publish-manifest-put.headers"
manifest_put_body="$source_dir/publish-manifest-put.body"
manifest_put_trace="$source_dir/publish-manifest-put.trace"
manifest_put_status=$(curl --silent --show-error \
  --request PUT \
  --header "Content-Type: $manifest_media_type" \
  --data-binary "@$manifest_file" \
  --dump-header "$manifest_put_headers" \
  --trace-ascii "$manifest_put_trace" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$synthetic_tag" \
  --output "$manifest_put_body")

if [ "$manifest_put_status" != "201" ]; then
  printf 'error: manifest PUT returned %s (expected 201)\n' "$manifest_put_status" >&2
  exit 1
fi

manifest_put_dcd=$(grep -i '^Docker-Content-Digest:' "$manifest_put_headers" \
  | head -1 | tr -d '\r' | awk '{print $2}')
if [ "$manifest_put_dcd" != "$manifest_digest" ]; then
  printf 'error: manifest PUT Docker-Content-Digest mismatch: got %s expected %s\n' \
    "$manifest_put_dcd" "$manifest_digest" >&2
  exit 1
fi
printf '  manifest PUT: %s  dcd=%s\n' "$manifest_put_status" "${manifest_put_dcd:-none}"

# ── 3. Fetch config by digest; verify byte identity ──────────────────────────

printf '\nVerifying config by digest...\n'

config_fetch_headers="$source_dir/publish-config-fetch.headers"
config_fetched="$source_dir/publish-config-fetch.body"
config_fetch_status=$(curl --silent --show-error \
  --dump-header "$config_fetch_headers" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/blobs/$config_digest" \
  --output "$config_fetched")

if [ "$config_fetch_status" != "200" ]; then
  printf 'error: config GET returned %s\n' "$config_fetch_status" >&2
  exit 1
fi

if ! cmp -s "$config_file" "$config_fetched"; then
  printf 'error: fetched config is not byte-identical to local config\n' >&2
  exit 1
fi
printf '  config fetch: %s  byte-identical=true\n' "$config_fetch_status"

# ── 4. Fetch manifest by digest and by tag; verify byte identity ─────────────

printf '\nVerifying manifest by digest...\n'

manifest_fetch_digest_headers="$source_dir/publish-manifest-fetch-by-digest.headers"
manifest_fetched_by_digest="$source_dir/publish-manifest-fetch-by-digest.body"
manifest_fetch_digest_status=$(curl --silent --show-error \
  --header "Accept: $manifest_media_type" \
  --dump-header "$manifest_fetch_digest_headers" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$manifest_digest" \
  --output "$manifest_fetched_by_digest")

if [ "$manifest_fetch_digest_status" != "200" ]; then
  printf 'error: manifest GET by digest returned %s\n' "$manifest_fetch_digest_status" >&2
  exit 1
fi

if ! cmp -s "$manifest_file" "$manifest_fetched_by_digest"; then
  printf 'error: fetched manifest (by digest) is not byte-identical to local manifest\n' >&2
  exit 1
fi
printf '  manifest by digest: %s  byte-identical=true\n' "$manifest_fetch_digest_status"

printf '\nVerifying manifest by tag...\n'

manifest_fetch_tag_headers="$source_dir/publish-manifest-fetch-by-tag.headers"
manifest_fetched_by_tag="$source_dir/publish-manifest-fetch-by-tag.body"
manifest_fetch_tag_status=$(curl --silent --show-error \
  --header "Accept: $manifest_media_type" \
  --dump-header "$manifest_fetch_tag_headers" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$synthetic_tag" \
  --output "$manifest_fetched_by_tag")

if [ "$manifest_fetch_tag_status" != "200" ]; then
  printf 'error: manifest GET by tag returned %s\n' "$manifest_fetch_tag_status" >&2
  exit 1
fi

if ! cmp -s "$manifest_file" "$manifest_fetched_by_tag"; then
  printf 'error: fetched manifest (by tag) is not byte-identical to local manifest\n' >&2
  exit 1
fi
printf '  manifest by tag: %s  byte-identical=true\n' "$manifest_fetch_tag_status"

# ── 5. Verify all three payload layer blobs under poc/synthetic ──────────────

printf '\nVerifying payload layer blobs through %s...\n' "$synthetic_repo"

layer_index=0
while [ "$layer_index" -lt 3 ]; do
  source_n=$((layer_index + 1))
  layer_digest=$(jq -r ".blobs[$layer_index].payload_layer.digest" \
    "$source_dir/blob-inventory.json")
  layer_expected_size=$(jq -r ".blobs[$layer_index].payload_layer.size" \
    "$source_dir/blob-inventory.json")

  layer_head_headers="$source_dir/publish-layer-${source_n}-head.headers"
  layer_head_status=$(curl --silent --show-error \
    --head \
    --dump-header "$layer_head_headers" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/$layer_digest" \
    --output /dev/null)

  if [ "$layer_head_status" != "200" ]; then
    printf 'error: layer %s HEAD returned %s in %s\n' \
      "$source_n" "$layer_head_status" "$synthetic_repo" >&2
    exit 1
  fi

  layer_get_headers="$source_dir/publish-layer-${source_n}-get.headers"
  layer_blob="$temporary/layer-${source_n}.tar.gz"
  layer_get_status=$(curl --silent --show-error \
    --dump-header "$layer_get_headers" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/$layer_digest" \
    --output "$layer_blob")

  if [ "$layer_get_status" != "200" ]; then
    printf 'error: layer %s GET returned %s\n' "$source_n" "$layer_get_status" >&2
    exit 1
  fi

  layer_body_digest="sha256:$(sha256sum "$layer_blob" | awk '{print $1}')"
  if [ "$layer_body_digest" != "$layer_digest" ]; then
    printf 'error: layer %s body digest mismatch: descriptor=%s body=%s\n' \
      "$source_n" "$layer_digest" "$layer_body_digest" >&2
    exit 1
  fi

  layer_body_size=$(wc -c < "$layer_blob" | tr -d '[:space:]')
  if [ "$layer_body_size" != "$layer_expected_size" ]; then
    printf 'error: layer %s size mismatch: expected=%s actual=%s\n' \
      "$source_n" "$layer_expected_size" "$layer_body_size" >&2
    exit 1
  fi

  printf '  layer %s: head=%s get=%s digest=OK size=OK\n' \
    "$source_n" "$layer_head_status" "$layer_get_status"
  layer_index=$((layer_index + 1))
done

# ── 6. Negative test: manifest with a nonexistent layer descriptor ───────────

printf '\nNegative test: manifest referencing a nonexistent layer...\n'

fake_digest="sha256:$(printf 'nonexistent-layer-blob' | sha256sum | awk '{print $1}')"
negative_manifest="$source_dir/publish-negative-put.request.json"

jq --null-input --compact-output \
  --arg config_digest  "$config_digest" \
  --argjson config_size "$config_size" \
  --arg fake_digest    "$fake_digest" \
  '{"schemaVersion":2,
    "mediaType":"application/vnd.oci.image.manifest.v1+json",
    "config":{"mediaType":"application/vnd.oci.image.config.v1+json",
              "digest":$config_digest,"size":$config_size},
    "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip",
               "digest":$fake_digest,"size":1}]}' \
  > "$negative_manifest"

negative_tag="negative-$run_id"
negative_put_headers="$source_dir/publish-negative-put.headers"
negative_put_body="$source_dir/publish-negative-put.body"
negative_put_trace="$source_dir/publish-negative-put.trace"
negative_put_status=$(curl --silent --show-error \
  --request PUT \
  --header "Content-Type: application/vnd.oci.image.manifest.v1+json" \
  --data-binary "@$negative_manifest" \
  --dump-header "$negative_put_headers" \
  --trace-ascii "$negative_put_trace" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$negative_tag" \
  --output "$negative_put_body")

negative_outcome=""
case "$negative_put_status" in
  400|404|422)
    negative_outcome="rejected"
    printf '  PUT returned %s — registry rejected manifest with unknown layer\n' \
      "$negative_put_status"
    ;;
  201)
    printf '  PUT returned 201 — registry accepted manifest with unknown layer\n'
    printf '  (registry:2 uses deferred blob validation; probing blob availability)\n'
    negative_blob_head_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --head \
      "http://$registry/v2/$synthetic_repo/blobs/$fake_digest")
    printf '  nonexistent blob HEAD: %s\n' "$negative_blob_head_status"
    if [ "$negative_blob_head_status" = "404" ]; then
      negative_outcome="accepted_blob_unavailable"
    else
      negative_outcome="accepted_blob_status_${negative_blob_head_status}"
    fi
    ;;
  *)
    negative_outcome="unexpected_status_${negative_put_status}"
    printf '  PUT returned %s (documented)\n' "$negative_put_status"
    ;;
esac

# ── 7. Write MANIFEST gate evidence ─────────────────────────────────────────

jq --null-input \
  --arg  run_id              "$run_id" \
  --arg  registry            "$registry" \
  --arg  synthetic_repo      "$synthetic_repo" \
  --arg  synthetic_tag       "$synthetic_tag" \
  --arg  config_digest       "$config_digest" \
  --argjson config_size      "$config_size" \
  --arg  config_put_status   "$config_put_status" \
  --arg  config_put_dcd      "${config_put_dcd:-}" \
  --arg  manifest_digest     "$manifest_digest" \
  --argjson manifest_size    "$manifest_size" \
  --arg  manifest_put_status "$manifest_put_status" \
  --arg  manifest_put_dcd    "${manifest_put_dcd:-}" \
  --arg  negative_fake_digest "$fake_digest" \
  --arg  negative_put_status "$negative_put_status" \
  --arg  negative_outcome    "$negative_outcome" \
  '{schema_version: 1,
    run_id: $run_id,
    gate: "MANIFEST",
    registry: $registry,
    synthetic_repository: $synthetic_repo,
    synthetic_tag: $synthetic_tag,
    config_upload: {
      digest: $config_digest,
      size: $config_size,
      put_status: $config_put_status,
      put_dcd: $config_put_dcd,
      fetch_byte_identical: true
    },
    manifest_publish: {
      digest: $manifest_digest,
      size: $manifest_size,
      put_status: $manifest_put_status,
      put_dcd: $manifest_put_dcd,
      fetch_by_digest_byte_identical: true,
      fetch_by_tag_byte_identical: true,
      no_layer_bytes_uploaded: true
    },
    layer_verification: {
      all_three_head_200: true,
      all_three_get_200: true,
      all_digests_match: true,
      all_sizes_match: true
    },
    negative_test: {
      fake_layer_digest: $negative_fake_digest,
      put_status: $negative_put_status,
      outcome: $negative_outcome
    }}' \
  > "$source_dir/publish-gate.json"

printf '\nManifest gate complete for run %s:\n' "$run_id"
printf '  config:    digest=%s  upload=%s\n' "$config_digest" "$config_put_status"
printf '  manifest:  digest=%s  put=%s\n' "$manifest_digest" "$manifest_put_status"
printf '  reference: %s/%s:%s\n' "$registry" "$synthetic_repo" "$synthetic_tag"
printf 'Evidence: %s/publish-gate.json\n' "$source_dir"
