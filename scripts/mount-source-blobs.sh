#!/bin/sh
#
# Probe synthetic-repository blob visibility and request cross-repository
# mounts (VISIBILITY gate).
#
# For each payload layer identified by a completed source-blobs run:
#   1. HEAD /v2/poc/synthetic/blobs/<digest> before any mount — records
#      whether the digest is accidentally visible through shared storage.
#   2. POST /v2/poc/synthetic/blobs/uploads/?mount=<digest>&from=poc/source-N
#      Only 201 Created is a successful mount; 202 Accepted starts an upload
#      session that is immediately aborted and the limitation recorded.
#   3. HEAD and GET the synthetic repository after the mount; verify that the
#      retrieved body hashes to the original source descriptor digest and
#      matches the original byte size.
#
# The POST body is intentionally empty — no layer content is uploaded on the
# successful path; the registry accepts the blob by reference to the source
# repository.  Raw HTTP status, Location, Docker-Content-Digest, and error
# bodies are preserved for every probe.
#
# Usage:  sh scripts/mount-source-blobs.sh <run-id>
#         make mount-blobs RUN_ID=<run-id>

set -eu

registry=${REGISTRY:-localhost:5000}
run_id=${1:?'run_id required; pass the run ID from a completed source-blobs run (make source-blobs RUN_ID=<id>)'}
source_dir="artifacts/source-images/$run_id"
synthetic_repo="poc/synthetic"

if [ ! -f "$source_dir/blob-inventory.json" ]; then
  printf 'error: blob-inventory.json not found at %s\n' "$source_dir/blob-inventory.json" >&2
  printf 'Run "make source-blobs RUN_ID=%s" first.\n' "$run_id" >&2
  exit 1
fi

if ! curl --fail --silent --show-error "http://$registry/v2/" >/dev/null; then
  printf 'error: registry not reachable at %s; run make registry-up\n' "$registry" >&2
  exit 1
fi

temporary=$(mktemp -d "$source_dir/mount-work.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

mount_failures=0
source_number=1
while [ "$source_number" -le 3 ]; do
  part_index=$((source_number - 1))
  source_repo=$(jq -r ".blobs[$part_index].repository" "$source_dir/blob-inventory.json")
  digest=$(jq -r ".blobs[$part_index].payload_layer.digest" "$source_dir/blob-inventory.json")
  expected_size=$(jq -r ".blobs[$part_index].payload_layer.size" "$source_dir/blob-inventory.json")
  digest_hex="${digest#sha256:}"

  printf 'source-%s: %s\n' "$source_number" "$digest"

  # 1. Pre-mount HEAD — detect accidental shared-storage visibility.
  pre_head_headers="$source_dir/mount-$source_number.pre-head.headers"
  pre_head_status=$(curl --silent --show-error \
    --head \
    --dump-header "$pre_head_headers" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/$digest" \
    --output /dev/null)
  pre_head_dcd=$(grep -i '^Docker-Content-Digest:' "$pre_head_headers" \
    | head -1 | tr -d '\r' | awk '{print $2}')
  printf '  pre-mount HEAD: %s\n' "$pre_head_status"

  case "$pre_head_status" in
    404) ;;
    200)
      printf '  note: digest already visible in %s before any mount (shared storage)\n' \
        "$synthetic_repo"
      ;;
    *)
      printf 'error: unexpected pre-mount HEAD status %s for %s\n' \
        "$pre_head_status" "$digest" >&2
      exit 1
      ;;
  esac

  # 2. Cross-repository mount.
  # POST body is empty; no layer content is sent to the upload endpoint.
  mount_headers="$source_dir/mount-$source_number.mount.headers"
  mount_body_file="$source_dir/mount-$source_number.mount.body"
  mount_trace="$source_dir/mount-$source_number.mount.trace"
  mount_status=$(curl --silent --show-error \
    --request POST \
    --header 'Content-Length: 0' \
    --dump-header "$mount_headers" \
    --trace-ascii "$mount_trace" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/uploads/?mount=$digest&from=$source_repo" \
    --output "$mount_body_file")
  if ! grep -q '^.*Content-Length: 0' "$mount_trace" || \
    grep -q '^=> Send data' "$mount_trace"; then
    printf 'error: mount trace does not prove an empty POST body for %s\n' \
      "$digest" >&2
    exit 1
  fi
  printf '  mount POST: %s\n' "$mount_status"

  mount_location=$(grep -i '^Location:' "$mount_headers" \
    | head -1 | tr -d '\r' | awk '{print $2}')
  mount_dcd=$(grep -i '^Docker-Content-Digest:' "$mount_headers" \
    | head -1 | tr -d '\r' | awk '{print $2}')

  mount_succeeded=false
  abort_result=""
  abort_headers=""
  abort_body_file=""

  case "$mount_status" in
    201)
      mount_succeeded=true
      if [ -n "$mount_dcd" ] && [ "$mount_dcd" != "$digest" ]; then
        printf 'error: mount Docker-Content-Digest mismatch: got %s expected %s\n' \
          "$mount_dcd" "$digest" >&2
        exit 1
      fi
      printf '  201 Created — cross-repository mount succeeded; no content was uploaded\n'
      ;;
    202)
      printf '  202 Accepted — registry does not support cross-repository mounting\n'
      if [ -n "$mount_location" ]; then
        case "$mount_location" in
          http://*|https://*) abort_url="$mount_location" ;;
          *) abort_url="http://$registry$mount_location" ;;
        esac
        abort_headers="$source_dir/mount-$source_number.abort.headers"
        abort_body_file="$source_dir/mount-$source_number.abort.body"
        abort_result=$(curl --silent --show-error \
          --request DELETE \
          --dump-header "$abort_headers" \
          --write-out '%{http_code}' \
          "$abort_url" \
          --output "$abort_body_file")
        printf '  aborted upload session at %s: %s\n' "$mount_location" "$abort_result"
      fi
      mount_failures=$((mount_failures + 1))
      ;;
    *)
      printf 'error: unexpected mount status %s for %s\n' "$mount_status" "$digest" >&2
      exit 1
      ;;
  esac

  # 3. Post-mount HEAD.
  post_head_headers="$source_dir/mount-$source_number.post-head.headers"
  post_head_status=$(curl --silent --show-error \
    --head \
    --dump-header "$post_head_headers" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/$digest" \
    --output /dev/null)
  post_head_dcd=$(grep -i '^Docker-Content-Digest:' "$post_head_headers" \
    | head -1 | tr -d '\r' | awk '{print $2}')
  printf '  post-mount HEAD: %s\n' "$post_head_status"

  if [ "$mount_status" = "201" ] && [ "$post_head_status" != "200" ]; then
    printf 'error: expected 200 from synthetic repository after successful mount, got %s\n' \
      "$post_head_status" >&2
    exit 1
  fi
  if [ "$post_head_status" = "200" ] && [ -n "$post_head_dcd" ] && \
    [ "$post_head_dcd" != "$digest" ]; then
    printf 'error: HEAD Docker-Content-Digest mismatch: got %s expected %s\n' \
      "$post_head_dcd" "$digest" >&2
    exit 1
  fi

  # 4. Post-mount GET — verify body digest and byte size.
  get_status=""
  body_digest=""
  body_size=""
  get_dcd=""

  if [ "$post_head_status" = "200" ]; then
    get_headers="$source_dir/mount-$source_number.get.headers"
    get_blob="$temporary/$digest_hex.tar.gz"
    get_status=$(curl --silent --show-error \
      --dump-header "$get_headers" \
      --write-out '%{http_code}' \
      "http://$registry/v2/$synthetic_repo/blobs/$digest" \
      --output "$get_blob")

    if [ "$get_status" != "200" ]; then
      printf 'error: GET returned %s for %s\n' "$get_status" "$digest" >&2
      exit 1
    fi

    body_digest="sha256:$(sha256sum "$get_blob" | awk '{print $1}')"
    if [ "$body_digest" != "$digest" ]; then
      printf 'error: body digest mismatch: descriptor=%s body=%s\n' \
        "$digest" "$body_digest" >&2
      exit 1
    fi

    body_size=$(wc -c <"$get_blob" | tr -d '[:space:]')
    if [ "$body_size" != "$expected_size" ]; then
      printf 'error: body size mismatch: descriptor=%s body=%s\n' \
        "$expected_size" "$body_size" >&2
      exit 1
    fi

    get_dcd=$(grep -i '^Docker-Content-Digest:' "$get_headers" \
      | head -1 | tr -d '\r' | awk '{print $2}')
    if [ -n "$get_dcd" ] && [ "$get_dcd" != "$digest" ]; then
      printf 'error: GET Docker-Content-Digest mismatch: got %s expected %s\n' \
        "$get_dcd" "$digest" >&2
      exit 1
    fi

    printf '  GET: digest=%s size=%s OK\n' "$body_digest" "$body_size"
  fi

  # Per-source result JSON.
  jq --null-input \
    --arg source "source-$source_number" \
    --arg source_repository "$source_repo" \
    --arg synthetic_repository "$synthetic_repo" \
    --arg digest "$digest" \
    --argjson expected_size "$expected_size" \
    --arg pre_mount_head_status "$pre_head_status" \
    --arg pre_mount_head_dcd "${pre_head_dcd:-}" \
    --arg mount_status "$mount_status" \
    --argjson mount_succeeded "$mount_succeeded" \
    --arg mount_location "${mount_location:-}" \
    --arg mount_dcd "${mount_dcd:-}" \
    --arg mount_trace "${mount_trace##*/}" \
    --arg abort_status "${abort_result:-}" \
    --arg abort_headers "${abort_headers##*/}" \
    --arg abort_body "${abort_body_file##*/}" \
    --arg post_mount_head_status "$post_head_status" \
    --arg post_mount_head_dcd "${post_head_dcd:-}" \
    --arg get_status "${get_status:-}" \
    --arg body_digest "${body_digest:-}" \
    --arg body_size "${body_size:-}" \
    --arg get_dcd "${get_dcd:-}" \
    '{source: $source,
      source_repository: $source_repository,
      synthetic_repository: $synthetic_repository,
      digest: $digest,
      expected_size: $expected_size,
      pre_mount_head_status: $pre_mount_head_status,
      pre_mount_visible: ($pre_mount_head_status == "200"),
      pre_mount_docker_content_digest: $pre_mount_head_dcd,
      mount_status: $mount_status,
      mount_succeeded: $mount_succeeded,
      mount_location: $mount_location,
      mount_docker_content_digest: $mount_dcd,
      mount_request_body_bytes: 0,
      mount_http_trace: $mount_trace,
      abort_status: $abort_status,
      abort_headers: $abort_headers,
      abort_body: $abort_body,
      post_mount_head_status: $post_mount_head_status,
      post_mount_docker_content_digest: $post_mount_head_dcd,
      get_status: $get_status,
      body_digest: $body_digest,
      body_size: ($body_size | if . == "" then null else tonumber end),
      get_docker_content_digest: $get_dcd}' \
    >"$source_dir/mount-$source_number.result.json"

  source_number=$((source_number + 1))
done

# VISIBILITY gate report.
jq --slurp \
  --arg run_id "$run_id" \
  --arg registry "$registry" \
  --arg synthetic_repo "$synthetic_repo" \
  '{schema_version: 1, run_id: $run_id, registry: $registry,
    synthetic_repository: $synthetic_repo, gate: "VISIBILITY", mounts: .}' \
  "$source_dir/mount-1.result.json" \
  "$source_dir/mount-2.result.json" \
  "$source_dir/mount-3.result.json" \
  >"$source_dir/visibility.json"

printf '\nVisibility gate evidence for run %s:\n' "$run_id"
jq -r '.mounts[] | "  \(.source): mount=\(.mount_status) post_head=\(.post_mount_head_status)"' \
  "$source_dir/visibility.json"

if [ "$mount_failures" -ne 0 ]; then
  printf '\nVISIBILITY gate FAILED: %s mount(s) returned 202 Accepted.\n' \
    "$mount_failures" >&2
  printf 'This registry does not support cross-repository mounting.\n' >&2
  printf 'The implementation must pause and evaluate one of:\n' >&2
  printf '  1. A different OCI-conforming local registry that supports mounting.\n' >&2
  printf '  2. An explicit same-byte upload (weaker claim: byte identity at the\n' >&2
  printf '     API boundary, not registry-side reuse; must be clearly labeled).\n' >&2
  printf 'Evidence retained at %s\n' "$source_dir" >&2
  exit 1
fi

printf 'Evidence: %s/visibility.json\n' "$source_dir"
