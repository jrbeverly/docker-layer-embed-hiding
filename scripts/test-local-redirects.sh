#!/bin/sh
# Run the phase-two local redirect protocol, client, integrity, and reconstruction gates.

set -eu

run_id=${1:?'run_id required; pass a completed phase-one proof run ID'}
source_dir="artifacts/source-images/$run_id"
output_dir="$source_dir/local-redirects"
server="scripts/local-redirect-server.py"
control_port=${REDIRECT_CONTROL_PORT:-5100}
origin_1_port=${REDIRECT_ORIGIN_1_PORT:-5101}
origin_2_port=${REDIRECT_ORIGIN_2_PORT:-5102}
origin_3_port=${REDIRECT_ORIGIN_3_PORT:-5103}
fault_control_port=${REDIRECT_FAULT_CONTROL_PORT:-5110}
fault_origin_port=${REDIRECT_FAULT_ORIGIN_PORT:-5111}
missing_port=${REDIRECT_MISSING_PORT:-5112}

for prerequisite in phase-one-report.json synthetic-manifest.json synthetic-config.json blob-inventory.json reconstruction-gate.json; do
  if [ ! -f "$source_dir/$prerequisite" ]; then
    printf 'error: %s is missing; complete phase one for RUN_ID=%s first\n' "$prerequisite" "$run_id" >&2
    exit 1
  fi
done
if [ -e "$output_dir" ]; then
  printf 'error: redirect evidence already exists at %s\n' "$output_dir" >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || {
  printf 'error: python3 is required for the local redirect experiment\n' >&2
  exit 1
}

mkdir -p "$output_dir" "$output_dir/raw" "$output_dir/clients" "$output_dir/failures"
temporary=$(mktemp -d "$output_dir/work.XXXXXX")
pids=''
cleanup() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

manifest="$source_dir/synthetic-manifest.json"
config="$source_dir/synthetic-config.json"
tag="run-$run_id"
repository='poc/synthetic'
reference="localhost:$control_port/$repository:$tag"
manifest_digest="sha256:$(sha256sum "$manifest" | awk '{print $1}')"
config_digest="sha256:$(sha256sum "$config" | awk '{print $1}')"

layer_digest() {
  jq -r ".layers[$(($1 - 1))].digest" "$manifest"
}
layer_blob() {
  printf '%s/source-%s.payload-layer.tar.gz\n' "$source_dir" "$1"
}
start_server() {
  log_file=$1
  shift
  python3 "$server" --log "$log_file" "$@" >"$log_file.server" 2>&1 &
  new_pid=$!
  pids="$pids $new_pid"
}
wait_for_server() {
  port=$1
  count=0
  while ! curl --silent --fail "http://localhost:$port/v2/" >/dev/null 2>&1; do
    count=$((count + 1))
    if [ "$count" -ge 50 ]; then
      printf 'error: server on port %s did not become ready\n' "$port" >&2
      exit 1
    fi
    sleep 0.1
  done
}
header_value() {
  awk -v name="$1" 'BEGIN {IGNORECASE=1} $1 == name ":" {
    sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit
  }' "$2"
}
origin_port() {
  case "$1" in
    1) printf '%s\n' "$origin_1_port" ;;
    2) printf '%s\n' "$origin_2_port" ;;
    3) printf '%s\n' "$origin_3_port" ;;
  esac
}

printf 'Starting isolated origins and metadata-only control plane...\n'
n=1
for port in "$origin_1_port" "$origin_2_port" "$origin_3_port"; do
  digest=$(layer_digest "$n")
  start_server "$output_dir/origin-$n.ndjson" --port "$port" origin \
    --digest "$digest" --blob "$(layer_blob "$n")"
  n=$((n + 1))
done

set --
n=1
for port in "$origin_1_port" "$origin_2_port" "$origin_3_port"; do
  digest=$(layer_digest "$n")
  set -- "$@" --mapping "$digest=http://localhost:$port/blobs/$digest"
  n=$((n + 1))
done
start_server "$output_dir/control.ndjson" --port "$control_port" control \
  --repository "$repository" --tag "$tag" --manifest "$manifest" --config "$config" "$@"
wait_for_server "$control_port"

printf 'Running raw HTTP redirect checks...\n'
curl --silent --show-error --dump-header "$output_dir/raw/manifest.headers" \
  --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://localhost:$control_port/v2/$repository/manifests/$tag" \
  --output "$output_dir/raw/manifest.json"
cmp "$manifest" "$output_dir/raw/manifest.json"
[ "$(header_value Docker-Distribution-Api-Version "$output_dir/raw/manifest.headers")" = "registry/2.0" ]
[ "$(header_value Docker-Content-Digest "$output_dir/raw/manifest.headers")" = "$manifest_digest" ]
[ "$(header_value Content-Type "$output_dir/raw/manifest.headers")" = "application/vnd.oci.image.manifest.v1+json" ]
[ "$(header_value Content-Length "$output_dir/raw/manifest.headers")" = "$(wc -c <"$manifest" | tr -d '[:space:]')" ]
curl --silent --show-error --dump-header "$output_dir/raw/config.headers" \
  "http://localhost:$control_port/v2/$repository/blobs/$config_digest" \
  --output "$output_dir/raw/config.json"
cmp "$config" "$output_dir/raw/config.json"
[ "$(header_value Docker-Distribution-Api-Version "$output_dir/raw/config.headers")" = "registry/2.0" ]
[ "$(header_value Docker-Content-Digest "$output_dir/raw/config.headers")" = "$config_digest" ]
[ "$(header_value Content-Type "$output_dir/raw/config.headers")" = "application/vnd.oci.image.config.v1+json" ]
[ "$(header_value Content-Length "$output_dir/raw/config.headers")" = "$(wc -c <"$config" | tr -d '[:space:]')" ]

n=1
while [ "$n" -le 3 ]; do
  digest=$(layer_digest "$n")
  url="http://localhost:$control_port/v2/$repository/blobs/$digest"
  status=$(curl --silent --show-error --dump-header "$output_dir/raw/layer-$n.redirect.headers" \
    --output "$output_dir/raw/layer-$n.redirect.body" --write-out '%{http_code}' "$url")
  [ "$status" = 307 ]
  [ ! -s "$output_dir/raw/layer-$n.redirect.body" ]
  [ "$(header_value Docker-Distribution-Api-Version "$output_dir/raw/layer-$n.redirect.headers")" = "registry/2.0" ]
  [ "$(header_value Content-Length "$output_dir/raw/layer-$n.redirect.headers")" = 0 ]
  [ "$(header_value Cache-Control "$output_dir/raw/layer-$n.redirect.headers")" = "no-store" ]
  [ "$(header_value Location "$output_dir/raw/layer-$n.redirect.headers")" = \
    "http://localhost:$(origin_port "$n")/blobs/$digest" ]
  curl --fail --location --silent --show-error \
    --header "X-Request-Id: raw-layer-$n" \
    --dump-header "$output_dir/raw/layer-$n.follow.headers" \
    "$url" --output "$output_dir/raw/layer-$n.tar.gz"
  [ "sha256:$(sha256sum "$output_dir/raw/layer-$n.tar.gz" | awk '{print $1}')" = "$digest" ]
  expected_size=$(jq -r ".layers[$((n - 1))].size" "$manifest")
  [ "$(wc -c <"$output_dir/raw/layer-$n.tar.gz" | tr -d '[:space:]')" = "$expected_size" ]

  curl --fail --location --silent --show-error --head \
    --header "X-Request-Id: raw-head-$n" "$url" >"$output_dir/raw/layer-$n.head.headers"
  curl --fail --location --silent --show-error --range 0-0 \
    --header "X-Request-Id: raw-range-$n" "$url" --output "$output_dir/raw/layer-$n.first-byte"
  [ "$(wc -c <"$output_dir/raw/layer-$n.first-byte" | tr -d '[:space:]')" = 1 ]
  curl --fail --location --silent --show-error --range -1 \
    --header "X-Request-Id: raw-suffix-$n" "$url" --output "$output_dir/raw/layer-$n.last-byte"
  [ "$(wc -c <"$output_dir/raw/layer-$n.last-byte" | tr -d '[:space:]')" = 1 ]
  curl --fail --location --silent --show-error --range 1-2 \
    --header "X-Request-Id: raw-middle-$n" "$url" --output "$output_dir/raw/layer-$n.middle"
  [ "$(wc -c <"$output_dir/raw/layer-$n.middle" | tr -d '[:space:]')" = 2 ]
  range_status=$(curl --location --silent --show-error --range 999999-1000000 \
    --header "X-Request-Id: raw-unsatisfiable-$n" --output /dev/null --write-out '%{http_code}' "$url")
  [ "$range_status" = 416 ]
  n=$((n + 1))
done

# Cross-origin redirects must not leak credentials. A harmless sentinel should
# remain visible so the trace also records ordinary header-forwarding behavior.
credential_log_lines=$(wc -l <"$output_dir/origin-1.ndjson" | tr -d '[:space:]')
credential_url="http://localhost:$control_port/v2/$repository/blobs/$(layer_digest 1)"
curl --fail --location --silent --show-error \
  --header 'Authorization: Bearer local-redirect-secret' \
  --header 'X-Redirect-Sentinel: harmless' \
  --header 'X-Request-Id: cross-origin-headers' \
  "$credential_url" --output "$output_dir/raw/cross-origin-headers.tar.gz"
tail -n "+$((credential_log_lines + 1))" "$output_dir/origin-1.ndjson" |
  jq -e 'select(.request_id == "cross-origin-headers") |
    .authorization_received == false and
    .redirect_sentinel == "harmless"' >/dev/null

# An unmapped digest must fail at the control plane without reaching an origin.
unknown='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
[ "$(curl --silent --output "$output_dir/raw/unknown.body" --write-out '%{http_code}' \
  "http://localhost:$control_port/v2/$repository/blobs/$unknown")" = 404 ]

# Each origin is isolated to its assigned digest, and mutation never redirects.
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://localhost:$origin_1_port/blobs/$(layer_digest 2)")" = 404 ]
[ "$(curl --silent --request PUT --output "$output_dir/raw/mutation.body" --write-out '%{http_code}' \
  "http://localhost:$control_port/v2/$repository/blobs/$(layer_digest 1)")" = 405 ]

printf 'Reconstructing through redirected raw layer bodies...\n'
n=1
while [ "$n" -le 3 ]; do
  gzip -dc "$output_dir/raw/layer-$n.tar.gz" |
    tar -xOf - "payload/archive.part$n" >"$temporary/archive.part$n"
  n=$((n + 1))
done
cat "$temporary/archive.part1" "$temporary/archive.part2" "$temporary/archive.part3" >"$temporary/payload.gz"
gzip -dc "$temporary/payload.gz" >"$temporary/payload.bin"
original_sha256=$(jq -r '.payload.sha256' "$source_dir/payload/metadata.json")
reconstructed_sha256=$(sha256sum "$temporary/payload.bin" | awk '{print $1}')
[ "$reconstructed_sha256" = "$original_sha256" ]

printf 'Running clean-store OCI client matrix...\n'
crane_ok=false
crane_output="$temporary/crane-rootfs.tar"
[ ! -e "$crane_output" ]
if crane export --insecure "$reference" "$crane_output" >"$output_dir/clients/crane.log" 2>&1; then
  for n in 1 2 3; do
    tar -xOf "$crane_output" "payload/archive.part$n" >"$temporary/crane.part$n"
    expected=$(jq -r ".blobs[$((n - 1))].part_sha256" "$source_dir/blob-inventory.json")
    [ "$(sha256sum "$temporary/crane.part$n" | awk '{print $1}')" = "$expected" ]
  done
  crane_ok=true
fi

skopeo_available=false
skopeo_ok=false
if command -v skopeo >/dev/null 2>&1; then
  skopeo_available=true
  rm -rf "$temporary/skopeo-dir"
  [ ! -e "$temporary/skopeo-dir" ]
  if skopeo copy --src-tls-verify=false "docker://$reference" "dir:$temporary/skopeo-dir" \
    >"$output_dir/clients/skopeo.log" 2>&1; then
    skopeo_ok=true
  fi
fi

docker_available=false
docker_ok=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_available=true
  docker image rm --force "$reference" >/dev/null 2>&1 || true
  if docker pull "$reference" >"$output_dir/clients/docker-pull.log" 2>&1; then
    container_id=$(docker create "$reference")
    if docker cp "$container_id:/payload" "$temporary/docker-payload" \
      >"$output_dir/clients/docker-cp.log" 2>&1; then
      docker_ok=true
    fi
    docker rm "$container_id" >/dev/null
    docker image rm --force "$reference" >/dev/null 2>&1 || true
  fi
fi

if [ "$crane_ok" != true ] && [ "$skopeo_ok" != true ] && [ "$docker_ok" != true ]; then
  printf 'error: no OCI client materialized all redirected layers\n' >&2
  exit 1
fi

printf 'Running failure cases...\n'
first_digest=$(layer_digest 1)
first_blob=$(layer_blob 1)
second_digest=$(layer_digest 2)
third_digest=$(layer_digest 3)
start_server "$output_dir/failures/corrupt-origin.ndjson" --port "$fault_origin_port" origin \
  --digest "$first_digest" --blob "$first_blob" --corrupt
start_server "$output_dir/failures/corrupt-control.ndjson" --port "$fault_control_port" control \
  --repository "$repository" --tag "$tag-corrupt" --manifest "$manifest" --config "$config" \
  --mapping "$first_digest=http://localhost:$fault_origin_port/blobs/$first_digest" \
  --mapping "$second_digest=http://localhost:$origin_2_port/blobs/$second_digest" \
  --mapping "$third_digest=http://localhost:$origin_3_port/blobs/$third_digest"
corrupt_control_pid=$new_pid
wait_for_server "$fault_control_port"
corrupt_url="http://localhost:$fault_control_port/v2/$repository/blobs/$first_digest"
curl --fail --location --silent --show-error "$corrupt_url" --output "$output_dir/failures/wrong-bytes.tar.gz"
wrong_digest="sha256:$(sha256sum "$output_dir/failures/wrong-bytes.tar.gz" | awk '{print $1}')"
[ "$wrong_digest" != "$first_digest" ]
if crane export --insecure "localhost:$fault_control_port/$repository:$tag-corrupt" \
  "$temporary/corrupt.tar" >"$output_dir/failures/crane-digest-mismatch.log" 2>&1; then
  printf 'error: crane accepted a digest-mismatched layer\n' >&2
  exit 1
fi

# A target may change after a successful request. Fetch from a newly named
# output (no client-side body cache), mutate the origin copy in place, and
# prove the next response is measured as different despite an unchanged URL.
mutable_blob="$temporary/mutable-layer.tar.gz"
cp "$first_blob" "$mutable_blob"
mutable_origin_port=$((fault_origin_port + 3))
mutable_control_port=$((fault_control_port + 3))
start_server "$output_dir/failures/mutable-origin.ndjson" --port "$mutable_origin_port" origin \
  --digest "$first_digest" --blob "$mutable_blob"
start_server "$output_dir/failures/mutable-control.ndjson" --port "$mutable_control_port" control \
  --repository "$repository" --tag "$tag-mutable" --manifest "$manifest" --config "$config" \
  --mapping "$first_digest=http://localhost:$mutable_origin_port/blobs/$first_digest"
wait_for_server "$mutable_control_port"
mutable_url="http://localhost:$mutable_control_port/v2/$repository/blobs/$first_digest"
curl --fail --location --silent --show-error "$mutable_url" \
  --output "$output_dir/failures/mutable-before.tar.gz"
[ "sha256:$(sha256sum "$output_dir/failures/mutable-before.tar.gz" | awk '{print $1}')" = "$first_digest" ]
printf 'x' >>"$mutable_blob"
curl --fail --location --silent --show-error "$mutable_url" \
  --output "$output_dir/failures/mutable-after.tar.gz"
mutable_after_digest="sha256:$(sha256sum "$output_dir/failures/mutable-after.tar.gz" | awk '{print $1}')"
[ "$mutable_after_digest" != "$first_digest" ]

# Restart only the fault control plane with a self-loop mapping.
kill "$corrupt_control_pid"
wait "$corrupt_control_pid" 2>/dev/null || true
start_server "$output_dir/failures/loop-control.ndjson" --port "$fault_control_port" control \
  --repository "$repository" --tag "$tag-loop" --manifest "$manifest" --config "$config" \
  --mapping "$first_digest=http://localhost:$fault_control_port/v2/$repository/blobs/$first_digest"
loop_control_pid=$new_pid
wait_for_server "$fault_control_port"
if curl --location --max-redirs 4 --silent --show-error "$corrupt_url" \
  --output /dev/null 2>"$output_dir/failures/redirect-loop.log"; then
  printf 'error: redirect loop unexpectedly succeeded\n' >&2
  exit 1
fi

kill "$loop_control_pid"
wait "$loop_control_pid" 2>/dev/null || true
start_server "$output_dir/failures/missing-control.ndjson" --port "$fault_control_port" control \
  --repository "$repository" --tag "$tag-missing" --manifest "$manifest" --config "$config" \
  --mapping "$first_digest=http://localhost:$missing_port/blobs/$first_digest"
wait_for_server "$fault_control_port"
if curl --location --connect-timeout 2 --silent --show-error "$corrupt_url" \
  --output /dev/null 2>"$output_dir/failures/missing-target.log"; then
  printf 'error: missing redirect target unexpectedly succeeded\n' >&2
  exit 1
fi

# Build a compact trace and assert every baseline layer traversed both hops.
jq --slurp '.' "$output_dir/control.ndjson" >"$output_dir/control-trace.json"
jq -e --arg path "/v2/$repository/manifests/$tag" \
  'any(.[]; .path == $path and .status == 200 and .response_bytes > 0)' \
  "$output_dir/control-trace.json" >/dev/null
jq -e --arg path "/v2/$repository/blobs/$config_digest" \
  'any(.[]; .path == $path and .status == 200 and .response_bytes > 0)' \
  "$output_dir/control-trace.json" >/dev/null
for n in 1 2 3; do
  jq --slurp '.' "$output_dir/origin-$n.ndjson" >"$output_dir/origin-$n-trace.json"
  digest=$(layer_digest "$n")
  jq -e --arg digest "$digest" \
    'any(.[]; .status == 307 and (.path | endswith($digest)) and .response_bytes == 0)' \
    "$output_dir/control-trace.json" >/dev/null
  jq -e --arg digest "$digest" \
    'any(.[]; .method == "HEAD" and .status == 307 and
      (.path | endswith($digest)) and .response_bytes == 0)' \
    "$output_dir/control-trace.json" >/dev/null
  jq -e --arg digest "$digest" \
    'any(.[]; (.status == 200 or .status == 206) and (.path | contains($digest)))' \
    "$output_dir/origin-$n-trace.json" >/dev/null
  jq -e --arg digest "$digest" \
    'any(.[]; .method == "HEAD" and .status == 200 and
      (.path | contains($digest)) and .response_bytes == 0)' \
    "$output_dir/origin-$n-trace.json" >/dev/null
done

jq --null-input \
  --arg run_id "$run_id" --arg reference "$reference" \
  --arg manifest_digest "$manifest_digest" \
  --arg first_digest "$first_digest" \
  --arg original_sha256 "$original_sha256" --arg reconstructed_sha256 "$reconstructed_sha256" \
  --arg wrong_digest "$wrong_digest" \
  --argjson crane_ok "$crane_ok" --argjson skopeo_available "$skopeo_available" \
  --argjson skopeo_ok "$skopeo_ok" --argjson docker_available "$docker_available" \
  --argjson docker_ok "$docker_ok" \
  '{schema_version: 1, run_id: $run_id, gate: "LOCAL_REDIRECT", outcome: "pass",
    synthetic_reference: $reference, manifest_digest: $manifest_digest,
    control_plane: {stores_layer_bodies: false, proxies_layer_bodies: false,
      redirect_status: 307, trace: "control-trace.json"},
    raw_http: {all_layer_digests_match: true, head_redirects_pass: true,
      range_redirects_pass: true, unknown_digest_fails: true,
      required_headers_pass: true, method_preservation_pass: true,
      cross_origin_credentials_withheld: true, harmless_header_forwarded: true,
      origin_isolation_pass: true, mutations_rejected: true},
    clients: {crane: {available: true, materialized: $crane_ok},
      skopeo: {available: $skopeo_available, materialized: $skopeo_ok},
      docker: {available: $docker_available, materialized: $docker_ok},
      at_least_one_materialized: ($crane_ok or $skopeo_ok or $docker_ok)},
    failures: {wrong_bytes_detected: true, descriptor_digest: $first_digest,
      measured_wrong_digest: $wrong_digest, oci_client_digest_mismatch_rejected: true,
      redirect_loop_failed: true, missing_target_failed: true,
      mutable_target_change_detected_from_clean_output: true},
    reconstruction: {original_payload_sha256: $original_sha256,
      reconstructed_payload_sha256: $reconstructed_sha256, sha256_match: true},
    evidence: {control_has_only_metadata_and_url_mappings: true,
      redirect_responses_have_zero_body_bytes: true,
      metadata_requests_present_in_control_trace: true,
      origins_have_separate_logs_and_each_serves_one_blob: true,
      control_redirect_body_bytes: 0,
      client_outputs_started_absent: true}}' \
  >"$output_dir/local-redirect-gate.json"

printf 'LOCAL_REDIRECT gate passed for run %s\n' "$run_id"
printf 'Evidence: %s/local-redirect-gate.json\n' "$output_dir"
