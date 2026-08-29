#!/bin/sh
#
# Test the synthetic image client compatibility matrix (MATERIALIZATION gate).
#
# Tests four client tiers against the published synthetic image in order:
#   1. Raw Distribution API (curl) — required baseline
#   2. crane manifest, config, and export
#   3. skopeo copy to OCI layout (if skopeo is available)
#   4. docker pull and docker create/cp file extraction (if Docker is reachable;
#      docker run runtime success is reported separately and is not required)
#
# The MATERIALIZATION gate passes when the raw Distribution API probe retrieves
# and verifies the exact manifest, config, and all three layer blobs (SHA-256
# and byte size matching the publish-gate descriptors), successfully extracts
# each payload part, and at least one standards-oriented OCI client materializes
# and verifies the object.
#
# Layer blobs are saved as matrix-api-layer-{1,2,3}.tar.gz for use by
# reconstruct-payload.sh.  All other client probes add evidence whether they
# succeed or fail; they do not block the gate.
#
# Evidence produced (all in artifacts/source-images/<run-id>/):
#   matrix-api-manifest-by-digest.headers / .json
#   matrix-api-manifest-by-tag.headers    / .json
#   matrix-api-config.headers             / .json
#   matrix-api-layer-{1,2,3}.tar.gz       (layer blobs; also used by reconstruct)
#   matrix-api-layer-{1,2,3}.headers
#   matrix-crane-manifest.json
#   matrix-crane-manifest.log
#   matrix-crane-config.json
#   matrix-crane-config.log
#   matrix-crane-export.tar
#   matrix-crane-export.log
#   matrix-crane-oci/                    (verified OCI layout from crane)
#   matrix-skopeo-copy.log
#   matrix-skopeo-oci/                    (OCI layout from skopeo; if available)
#   matrix-docker-pull.log
#   matrix-docker-create.log
#   matrix-docker-run.log
#   client-matrix-gate.json
#
# Usage:  sh scripts/test-client-matrix.sh <run-id>
#         make client-matrix RUN_ID=<run-id>

set -eu

registry=${REGISTRY:-localhost:5000}
run_id=${1:?'run_id required; pass the run ID from a completed publish-synthetic run'}
source_dir="artifacts/source-images/$run_id"
synthetic_repo="poc/synthetic"
synthetic_tag="run-$run_id"
synthetic_ref="$registry/$synthetic_repo:$synthetic_tag"

# ── Prerequisite checks ──────────────────────────────────────────────────────

for prereq in blob-inventory.json synthetic-config.json synthetic-manifest.json publish-gate.json; do
  if [ ! -f "$source_dir/$prereq" ]; then
    printf 'error: %s not found; run make publish-synthetic RUN_ID=%s first\n' \
      "$prereq" "$run_id" >&2
    exit 1
  fi
done

if [ -f "$source_dir/client-matrix-gate.json" ]; then
  printf 'error: client-matrix-gate.json already exists at %s\n' "$source_dir" >&2
  exit 1
fi

if ! curl --fail --silent --show-error "http://$registry/v2/" >/dev/null; then
  printf 'error: registry not reachable at %s; run make registry-up\n' "$registry" >&2
  exit 1
fi

manifest_file="$source_dir/synthetic-manifest.json"
config_file="$source_dir/synthetic-config.json"
manifest_media_type=$(jq -r '.mediaType' "$manifest_file")
manifest_digest="sha256:$(sha256sum "$manifest_file" | awk '{print $1}')"
config_digest="sha256:$(sha256sum "$config_file" | awk '{print $1}')"

temporary=$(mktemp -d "$source_dir/matrix-work.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# ── Probe 1: Raw Distribution API (curl) ─────────────────────────────────────

printf '\n── Probe 1: Raw Distribution API ────────────────────────────────────────────\n'
printf 'curl %s\n' "$(curl --version | head -1)"

api_manifest_digest_ok=false
api_manifest_tag_ok=false
api_config_ok=false
api_layers_ok=false
api_parts_ok=false
api_outcome="error"

# Fetch manifest by digest.
api_mfst_digest_hdrs="$source_dir/matrix-api-manifest-by-digest.headers"
api_mfst_digest_file="$source_dir/matrix-api-manifest-by-digest.json"
api_mfst_digest_status=$(curl --silent --show-error \
  --header "Accept: $manifest_media_type" \
  --dump-header "$api_mfst_digest_hdrs" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$manifest_digest" \
  --output "$api_mfst_digest_file")

if [ "$api_mfst_digest_status" = "200" ]; then
  if cmp -s "$manifest_file" "$api_mfst_digest_file"; then
    api_manifest_digest_ok=true
    printf '  manifest by digest: %s  byte-identical=true\n' "$api_mfst_digest_status"
  else
    printf '  manifest by digest: %s  byte-identical=FALSE\n' "$api_mfst_digest_status" >&2
    exit 1
  fi
else
  printf 'error: manifest GET by digest returned %s\n' "$api_mfst_digest_status" >&2
  exit 1
fi

# Fetch manifest by tag.
api_mfst_tag_hdrs="$source_dir/matrix-api-manifest-by-tag.headers"
api_mfst_tag_file="$source_dir/matrix-api-manifest-by-tag.json"
api_mfst_tag_status=$(curl --silent --show-error \
  --header "Accept: $manifest_media_type" \
  --dump-header "$api_mfst_tag_hdrs" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/manifests/$synthetic_tag" \
  --output "$api_mfst_tag_file")

if [ "$api_mfst_tag_status" = "200" ]; then
  if cmp -s "$manifest_file" "$api_mfst_tag_file"; then
    api_manifest_tag_ok=true
    printf '  manifest by tag:    %s  byte-identical=true\n' "$api_mfst_tag_status"
  else
    printf '  manifest by tag:    %s  byte-identical=FALSE\n' "$api_mfst_tag_status" >&2
    exit 1
  fi
else
  printf 'error: manifest GET by tag returned %s\n' "$api_mfst_tag_status" >&2
  exit 1
fi

# Fetch config blob.
api_config_hdrs="$source_dir/matrix-api-config.headers"
api_config_fetched="$temporary/api-config-fetched.json"
api_config_status=$(curl --silent --show-error \
  --dump-header "$api_config_hdrs" \
  --write-out '%{http_code}' \
  "http://$registry/v2/$synthetic_repo/blobs/$config_digest" \
  --output "$api_config_fetched")

if [ "$api_config_status" = "200" ]; then
  if cmp -s "$config_file" "$api_config_fetched"; then
    api_config_ok=true
    printf '  config blob:        %s  byte-identical=true\n' "$api_config_status"
  else
    printf '  config blob:        %s  byte-identical=FALSE\n' "$api_config_status" >&2
    exit 1
  fi
else
  printf 'error: config GET returned %s\n' "$api_config_status" >&2
  exit 1
fi

# Fetch each layer blob; save persistently for reconstruct-payload.sh.
printf '  layer blobs:\n'
layer_index=0
api_layers_all_ok=true
api_parts_all_ok=true

while [ "$layer_index" -lt 3 ]; do
  source_n=$((layer_index + 1))
  layer_digest=$(jq -r ".blobs[$layer_index].payload_layer.digest" \
    "$source_dir/blob-inventory.json")
  layer_expected_size=$(jq -r ".blobs[$layer_index].payload_layer.size" \
    "$source_dir/blob-inventory.json")
  expected_part_sha256=$(jq -r ".blobs[$layer_index].part_sha256" \
    "$source_dir/blob-inventory.json")
  part_path="payload/archive.part$source_n"

  layer_blob="$source_dir/matrix-api-layer-${source_n}.tar.gz"
  layer_hdrs="$source_dir/matrix-api-layer-${source_n}.headers"

  layer_status=$(curl --silent --show-error \
    --dump-header "$layer_hdrs" \
    --write-out '%{http_code}' \
    "http://$registry/v2/$synthetic_repo/blobs/$layer_digest" \
    --output "$layer_blob")

  if [ "$layer_status" != "200" ]; then
    printf '    layer %s: GET returned %s\n' "$source_n" "$layer_status" >&2
    api_layers_all_ok=false
    layer_index=$((layer_index + 1))
    continue
  fi

  body_digest="sha256:$(sha256sum "$layer_blob" | awk '{print $1}')"
  body_size=$(wc -c < "$layer_blob" | tr -d '[:space:]')

  if [ "$body_digest" != "$layer_digest" ]; then
    printf '    layer %s: digest mismatch: descriptor=%s body=%s\n' \
      "$source_n" "$layer_digest" "$body_digest" >&2
    api_layers_all_ok=false
    layer_index=$((layer_index + 1))
    continue
  fi

  if [ "$body_size" != "$layer_expected_size" ]; then
    printf '    layer %s: size mismatch: expected=%s actual=%s\n' \
      "$source_n" "$layer_expected_size" "$body_size" >&2
    api_layers_all_ok=false
    layer_index=$((layer_index + 1))
    continue
  fi

  # Decompress and extract the payload part; verify against inventory sha256.
  layer_tar="$temporary/layer-${source_n}.tar"
  gzip -dc "$layer_blob" > "$layer_tar"
  extracted_sha256=$(tar -xOf "$layer_tar" "$part_path" | sha256sum | awk '{print $1}')

  if [ "$extracted_sha256" != "$expected_part_sha256" ]; then
    printf '    layer %s: part sha256 mismatch: expected=%s extracted=%s\n' \
      "$source_n" "$expected_part_sha256" "$extracted_sha256" >&2
    api_parts_all_ok=false
  else
    printf '    layer %s: GET %s  digest=OK size=OK  %s sha256=OK\n' \
      "$source_n" "$layer_status" "$part_path"
  fi

  layer_index=$((layer_index + 1))
done

if $api_layers_all_ok; then
  api_layers_ok=true
fi
if $api_parts_all_ok; then
  api_parts_ok=true
fi

if $api_layers_ok && $api_parts_ok; then
  api_outcome="ok"
  printf '  API probe: PASS\n'
else
  printf 'error: raw Distribution API probe failed\n' >&2
  exit 1
fi

# ── Probe 2: crane ───────────────────────────────────────────────────────────

printf '\n── Probe 2: crane ───────────────────────────────────────────────────────────\n'

crane_available=false
crane_version="none"
crane_manifest_byte_identical=false
crane_manifest_media_type=""
crane_manifest_conversion=""
crane_config_byte_identical=false
crane_export_has_all_parts=false
crane_layers_verified=false
crane_outcome="skipped"

if command -v crane >/dev/null 2>&1; then
  crane_available=true
  crane_version=$(crane version 2>/dev/null | tr -d '\r\n' || printf 'unknown')
  printf 'crane version: %s\n' "$crane_version"

  # crane manifest: fetch raw manifest and compare.
  crane_manifest_file="$source_dir/matrix-crane-manifest.json"
  if crane manifest "$synthetic_ref" \
      > "$crane_manifest_file" \
      2>"$source_dir/matrix-crane-manifest.log"; then

    crane_manifest_media_type=$(jq -r '.mediaType // empty' "$crane_manifest_file")
    local_media_type=$(jq -r '.mediaType' "$manifest_file")

    if cmp -s "$manifest_file" "$crane_manifest_file"; then
      crane_manifest_byte_identical=true
      crane_manifest_conversion="none"
      printf '  crane manifest: byte-identical=true  mediaType=%s\n' "$crane_manifest_media_type"
    else
      if [ "$crane_manifest_media_type" != "$local_media_type" ]; then
        crane_manifest_conversion="oci-to-docker: local=$local_media_type fetched=$crane_manifest_media_type"
        printf '  crane manifest: CONVERSION DETECTED: %s\n' "$crane_manifest_conversion"
      else
        crane_manifest_conversion="non-identical (same mediaType; whitespace or field order)"
        printf '  crane manifest: not byte-identical (same mediaType)\n'
      fi
    fi
  else
    crane_outcome="error"
    printf '  crane manifest: FAILED (see matrix-crane-manifest.log)\n'
  fi

  # crane config: fetch raw config and compare.
  if [ "$crane_outcome" != "error" ]; then
    crane_config_file="$source_dir/matrix-crane-config.json"
    if crane config "$synthetic_ref" \
        > "$crane_config_file" \
        2>"$source_dir/matrix-crane-config.log"; then

      if cmp -s "$config_file" "$crane_config_file"; then
        crane_config_byte_identical=true
        printf '  crane config:   byte-identical=true\n'
      else
        printf '  crane config:   not byte-identical (inspect matrix-crane-config.json)\n'
      fi
    else
      printf '  crane config:   FAILED (see matrix-crane-config.log)\n'
    fi
  fi

  # crane pull: materialize an OCI layout and verify the exact descriptors and
  # compressed layer bytes, so a successful export alone is not treated as
  # proof that the source blobs were preserved.
  if [ "$crane_outcome" != "error" ]; then
    crane_oci_dir="$source_dir/matrix-crane-oci"
    if crane pull --format=oci "$synthetic_ref" "$crane_oci_dir" \
        2>"$source_dir/matrix-crane-pull.log"; then
      crane_layout_manifest_digest=$(jq -r '.manifests[0].digest' \
        "$crane_oci_dir/index.json")
      crane_layout_manifest="$crane_oci_dir/blobs/sha256/${crane_layout_manifest_digest#sha256:}"
      crane_layers_verified=true
      if ! cmp -s "$manifest_file" "$crane_layout_manifest"; then
        crane_layers_verified=false
        printf '  crane OCI layout: manifest rewrite detected\n'
      fi
      for n in 1 2 3; do
        expected_digest=$(jq -r ".layers[$((n - 1))].digest" "$manifest_file")
        expected_size=$(jq -r ".layers[$((n - 1))].size" "$manifest_file")
        expected_media_type=$(jq -r ".layers[$((n - 1))].mediaType" "$manifest_file")
        actual_digest=$(jq -r ".layers[$((n - 1))].digest" "$crane_layout_manifest")
        actual_size=$(jq -r ".layers[$((n - 1))].size" "$crane_layout_manifest")
        actual_media_type=$(jq -r ".layers[$((n - 1))].mediaType" "$crane_layout_manifest")
        layer_path="$crane_oci_dir/blobs/sha256/${actual_digest#sha256:}"
        measured_digest="sha256:$(sha256sum "$layer_path" | awk '{print $1}')"
        measured_size=$(wc -c < "$layer_path" | tr -d '[:space:]')
        if [ "$actual_digest" != "$expected_digest" ] || \
            [ "$actual_size" != "$expected_size" ] || \
            [ "$actual_media_type" != "$expected_media_type" ] || \
            [ "$measured_digest" != "$expected_digest" ] || \
            [ "$measured_size" != "$expected_size" ]; then
          crane_layers_verified=false
          printf '  crane OCI layout layer %s: descriptor or bytes rewritten\n' "$n"
        fi
      done
      printf '  crane OCI layout: layers_verified=%s\n' "$crane_layers_verified"
    else
      printf '  crane pull: FAILED (see matrix-crane-pull.log)\n'
    fi
  fi

  # crane export: export merged filesystem; verify all three part paths present.
  if [ "$crane_outcome" != "error" ]; then
    crane_export_file="$source_dir/matrix-crane-export.tar"
    if crane export "$synthetic_ref" "$crane_export_file" \
        2>"$source_dir/matrix-crane-export.log"; then

      crane_parts_found=0
      crane_export_has_all_parts=true
      for n in 1 2 3; do
        part_name="archive.part$n"
        if tar -tf "$crane_export_file" 2>/dev/null | grep -qF "$part_name"; then
          crane_parts_found=$((crane_parts_found + 1))
          printf '  crane export:   found payload/archive.part%s\n' "$n"
        else
          crane_export_has_all_parts=false
          printf '  crane export:   MISSING payload/archive.part%s\n' "$n"
        fi
      done
    else
      crane_export_has_all_parts=false
      printf '  crane export:   FAILED (see matrix-crane-export.log)\n'
    fi
  fi

  if [ "$crane_outcome" != "error" ] && \
      $crane_manifest_byte_identical && $crane_config_byte_identical && \
      $crane_export_has_all_parts && $crane_layers_verified; then
    crane_outcome="ok"
    printf '  crane probe: PASS\n'
  else
    crane_outcome="error"
    printf '  crane probe: FAILED\n'
  fi
else
  printf 'crane not available; skipping crane probe\n'
fi

# ── Probe 3: skopeo ──────────────────────────────────────────────────────────

printf '\n── Probe 3: skopeo ──────────────────────────────────────────────────────────\n'

skopeo_available=false
skopeo_version="none"
skopeo_manifest_digest=""
skopeo_manifest_byte_identical=false
skopeo_manifest_media_type=""
skopeo_manifest_conversion=""
skopeo_config_byte_identical=false
skopeo_layers_verified=false
skopeo_outcome="skipped"

if command -v skopeo >/dev/null 2>&1; then
  skopeo_available=true
  skopeo_version=$(skopeo --version 2>/dev/null | tr -d '\r\n' || printf 'unknown')
  printf 'skopeo version: %s\n' "$skopeo_version"

  skopeo_oci_dir="$source_dir/matrix-skopeo-oci"
  if skopeo copy \
      --src-tls-verify=false \
      "docker://$synthetic_ref" \
      "oci:${skopeo_oci_dir}:${synthetic_tag}" \
      >"$source_dir/matrix-skopeo-copy.log" 2>&1; then

    # Read index.json to find the manifest digest in the OCI layout.
    skopeo_index="$skopeo_oci_dir/index.json"
    skopeo_mfst_digest=$(jq -r '.manifests[0].digest' "$skopeo_index")
    skopeo_mfst_hex="${skopeo_mfst_digest#sha256:}"
    skopeo_mfst_blob="$skopeo_oci_dir/blobs/sha256/$skopeo_mfst_hex"

    skopeo_manifest_digest="$skopeo_mfst_digest"
    skopeo_manifest_media_type=$(jq -r '.mediaType // empty' "$skopeo_mfst_blob")
    local_media_type=$(jq -r '.mediaType' "$manifest_file")

    if cmp -s "$manifest_file" "$skopeo_mfst_blob"; then
      skopeo_manifest_byte_identical=true
      skopeo_manifest_conversion="none"
      printf '  skopeo manifest: byte-identical=true  mediaType=%s\n' \
        "$skopeo_manifest_media_type"
    else
      if [ "$skopeo_manifest_media_type" != "$local_media_type" ]; then
        skopeo_manifest_conversion="oci-to-docker: local=$local_media_type fetched=$skopeo_manifest_media_type"
        printf '  skopeo manifest: CONVERSION DETECTED: %s\n' "$skopeo_manifest_conversion"
      else
        skopeo_manifest_conversion="non-identical (same mediaType)"
        printf '  skopeo manifest: not byte-identical (same mediaType)\n'
      fi
    fi

    skopeo_config_digest=$(jq -r '.config.digest' "$skopeo_mfst_blob")
    skopeo_config_blob="$skopeo_oci_dir/blobs/sha256/${skopeo_config_digest#sha256:}"
    if [ "$skopeo_config_digest" = "$config_digest" ] && \
        cmp -s "$config_file" "$skopeo_config_blob"; then
      skopeo_config_byte_identical=true
    fi

    skopeo_layers_verified=true
    for n in 1 2 3; do
      expected_digest=$(jq -r ".layers[$((n - 1))].digest" "$manifest_file")
      expected_size=$(jq -r ".layers[$((n - 1))].size" "$manifest_file")
      expected_media_type=$(jq -r ".layers[$((n - 1))].mediaType" "$manifest_file")
      actual_digest=$(jq -r ".layers[$((n - 1))].digest" "$skopeo_mfst_blob")
      actual_size=$(jq -r ".layers[$((n - 1))].size" "$skopeo_mfst_blob")
      actual_media_type=$(jq -r ".layers[$((n - 1))].mediaType" "$skopeo_mfst_blob")
      layer_path="$skopeo_oci_dir/blobs/sha256/${actual_digest#sha256:}"
      measured_digest="sha256:$(sha256sum "$layer_path" | awk '{print $1}')"
      measured_size=$(wc -c < "$layer_path" | tr -d '[:space:]')
      if [ "$actual_digest" != "$expected_digest" ] || \
          [ "$actual_size" != "$expected_size" ] || \
          [ "$actual_media_type" != "$expected_media_type" ] || \
          [ "$measured_digest" != "$expected_digest" ] || \
          [ "$measured_size" != "$expected_size" ]; then
        skopeo_layers_verified=false
      fi
    done

    if $skopeo_manifest_byte_identical && $skopeo_config_byte_identical && \
        $skopeo_layers_verified; then
      skopeo_outcome="ok"
      printf '  skopeo probe: PASS\n'
    else
      skopeo_outcome="error"
      printf '  skopeo probe: metadata or layer rewrite detected\n'
    fi
  else
    skopeo_outcome="error"
    printf '  skopeo copy FAILED (see matrix-skopeo-copy.log)\n'
  fi
else
  printf 'skopeo not available; skipping skopeo probe\n'
fi

# ── Probe 4: docker ──────────────────────────────────────────────────────────

printf '\n── Probe 4: docker ──────────────────────────────────────────────────────────\n'

docker_available=false
docker_version="none"
docker_pull_outcome="skipped"
docker_unpack_outcome="skipped"
docker_runtime_outcome="skipped"
docker_runtime_note=""
docker_metadata_format="not-observed"
docker_saved_layers_verified=false

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_available=true
  docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null \
    | tr -d '\r\n' || printf 'unknown')
  printf 'docker version: %s\n' "$docker_version"

  # docker pull.
  if docker pull "$synthetic_ref" \
      >"$source_dir/matrix-docker-pull.log" 2>&1; then
    docker_pull_outcome="ok"
    printf '  docker pull: OK\n'

    docker image inspect "$synthetic_ref" \
      >"$source_dir/matrix-docker-image-inspect.json"
    docker_save="$source_dir/matrix-docker-save.tar"
    if docker save --output "$docker_save" "$synthetic_ref" \
        2>"$source_dir/matrix-docker-save.log"; then
      tar -xOf "$docker_save" manifest.json \
        >"$source_dir/matrix-docker-save-manifest.json"
      docker_metadata_format="docker-save-legacy-manifest"
      docker_saved_layers_verified=true
      for n in 1 2 3; do
        saved_layer=$(jq -r ".[0].Layers[$((n - 1))]" \
          "$source_dir/matrix-docker-save-manifest.json")
        measured_digest="sha256:$(tar -xOf "$docker_save" "$saved_layer" | sha256sum | awk '{print $1}')"
        measured_size=$(tar -xOf "$docker_save" "$saved_layer" | wc -c | tr -d '[:space:]')
        expected_digest=$(jq -r ".layers[$((n - 1))].digest" "$manifest_file")
        expected_size=$(jq -r ".layers[$((n - 1))].size" "$manifest_file")
        if [ "$measured_digest" != "$expected_digest" ] || \
            [ "$measured_size" != "$expected_size" ]; then
          docker_saved_layers_verified=false
        fi
      done
      printf '  docker save: metadata_format=%s layer_blobs_verified=%s\n' \
        "$docker_metadata_format" "$docker_saved_layers_verified"
    else
      printf '  docker save: FAILED (see matrix-docker-save.log)\n'
    fi

    # docker create + docker cp to extract files (pull/unpack test, not runtime).
    # A minimal OCI config with no Cmd/Entrypoint requires an explicit command
    # here; /bin/true is supplied only to satisfy the daemon's requirement — it
    # does not need to exist in the image for docker create to succeed.
    container_name="matrix-${run_id}"
    if docker create --name "$container_name" "$synthetic_ref" /bin/true \
        >"$source_dir/matrix-docker-create.log" 2>&1; then

      unpack_ok=true
      for n in 1 2 3; do
        if docker cp \
            "${container_name}:/payload/archive.part${n}" \
            "$temporary/docker-part${n}" \
            >>"$source_dir/matrix-docker-create.log" 2>&1; then
          extracted_sha256=$(sha256sum "$temporary/docker-part${n}" | awk '{print $1}')
          expected_sha256=$(jq -r ".blobs[$((n - 1))].part_sha256" \
            "$source_dir/blob-inventory.json")
          if [ "$extracted_sha256" = "$expected_sha256" ]; then
            printf '  docker cp /payload/archive.part%s: sha256=OK\n' "$n"
          else
            printf '  docker cp /payload/archive.part%s: sha256 MISMATCH\n' "$n"
            unpack_ok=false
          fi
        else
          printf '  docker cp /payload/archive.part%s: FAILED\n' "$n"
          unpack_ok=false
        fi
      done

      docker rm "$container_name" >/dev/null 2>&1 || true

      if $unpack_ok; then
        docker_unpack_outcome="ok"
      else
        docker_unpack_outcome="error"
      fi
    else
      docker rm "$container_name" >/dev/null 2>&1 || true
      docker_unpack_outcome="error"
      printf '  docker create: FAILED (see matrix-docker-create.log)\n'
    fi

    # Runtime test: reported separately; failure is expected for a minimal image.
    printf '  docker run (runtime; failure expected for minimal image):\n'
    if docker run --rm "$synthetic_ref" sh -c 'ls /payload/' \
        >"$source_dir/matrix-docker-run.log" 2>&1; then
      docker_runtime_outcome="ok"
      docker_runtime_note="shell invocation succeeded"
    else
      docker_runtime_exit=$?
      docker_runtime_outcome="failed"
      docker_runtime_note="exit $docker_runtime_exit (no shell in minimal image; see matrix-docker-run.log)"
    fi
    printf '  docker runtime: %s — %s\n' "$docker_runtime_outcome" "$docker_runtime_note"

  else
    docker_pull_outcome="error"
    printf '  docker pull: FAILED (see matrix-docker-pull.log)\n'
  fi
else
  printf 'Docker daemon not reachable; skipping docker probe\n'
fi

standards_client_materialized=false
if [ "$crane_outcome" = "ok" ] || [ "$skopeo_outcome" = "ok" ] || \
    [ "$docker_unpack_outcome" = "ok" ]; then
  standards_client_materialized=true
fi
if ! $standards_client_materialized; then
  printf 'error: no standards-oriented OCI client materialized and verified the image\n' >&2
  printf 'The valid-image failure evidence above must be resolved before considering the artifact fallback.\n' >&2
  exit 1
fi

# ── MATERIALIZATION gate evidence ─────────────────────────────────────────────

printf '\nWriting MATERIALIZATION gate evidence...\n'

# Build layer verification JSON array.
layer_array="["
layer_index=0
while [ "$layer_index" -lt 3 ]; do
  source_n=$((layer_index + 1))
  ld=$(jq -r ".blobs[$layer_index].payload_layer.digest" "$source_dir/blob-inventory.json")
  ls=$(jq -r ".blobs[$layer_index].payload_layer.size"   "$source_dir/blob-inventory.json")
  lmt=$(jq -r ".blobs[$layer_index].payload_layer.mediaType" "$source_dir/blob-inventory.json")
  psha=$(jq -r ".blobs[$layer_index].part_sha256" "$source_dir/blob-inventory.json")
  sep=""
  if [ "$layer_index" -gt 0 ]; then sep=","; fi
  layer_array="${layer_array}${sep}{\"layer\":$source_n,\"digest\":\"$ld\",\"size\":$ls,\"mediaType\":\"$lmt\",\"part_sha256_ok\":true,\"blob_file\":\"matrix-api-layer-${source_n}.tar.gz\"}"
  layer_index=$((layer_index + 1))
done
layer_array="${layer_array}]"

jq --null-input \
  --arg  run_id             "$run_id" \
  --arg  registry           "$registry" \
  --arg  synthetic_repo     "$synthetic_repo" \
  --arg  synthetic_tag      "$synthetic_tag" \
  --arg  manifest_digest    "$manifest_digest" \
  --arg  api_outcome        "$api_outcome" \
  --argjson api_manifest_digest_ok  "$api_manifest_digest_ok" \
  --argjson api_manifest_tag_ok     "$api_manifest_tag_ok" \
  --argjson api_config_ok           "$api_config_ok" \
  --argjson api_layers_ok           "$api_layers_ok" \
  --argjson api_parts_ok            "$api_parts_ok" \
  --argjson layer_verification      "$layer_array" \
  --argjson crane_available         "$crane_available" \
  --arg  crane_version              "$crane_version" \
  --arg  crane_outcome              "$crane_outcome" \
  --argjson crane_manifest_byte_identical "$crane_manifest_byte_identical" \
  --arg  crane_manifest_media_type  "$crane_manifest_media_type" \
  --arg  crane_manifest_conversion  "$crane_manifest_conversion" \
  --argjson crane_config_byte_identical  "$crane_config_byte_identical" \
  --argjson crane_export_has_all_parts   "$crane_export_has_all_parts" \
  --argjson crane_layers_verified        "$crane_layers_verified" \
  --argjson skopeo_available        "$skopeo_available" \
  --arg  skopeo_version             "$skopeo_version" \
  --arg  skopeo_outcome             "$skopeo_outcome" \
  --argjson skopeo_manifest_byte_identical "$skopeo_manifest_byte_identical" \
  --arg  skopeo_manifest_media_type "$skopeo_manifest_media_type" \
  --arg  skopeo_manifest_conversion "$skopeo_manifest_conversion" \
  --argjson skopeo_config_byte_identical "$skopeo_config_byte_identical" \
  --argjson skopeo_layers_verified       "$skopeo_layers_verified" \
  --argjson docker_available        "$docker_available" \
  --arg  docker_version             "$docker_version" \
  --arg  docker_pull_outcome        "$docker_pull_outcome" \
  --arg  docker_unpack_outcome      "$docker_unpack_outcome" \
  --arg  docker_runtime_outcome     "$docker_runtime_outcome" \
  --arg  docker_runtime_note        "$docker_runtime_note" \
  --arg  docker_metadata_format     "$docker_metadata_format" \
  --argjson docker_saved_layers_verified "$docker_saved_layers_verified" \
  --argjson standards_client_materialized "$standards_client_materialized" \
  '{schema_version: 1,
    run_id: $run_id,
    gate: "MATERIALIZATION",
    registry: $registry,
    synthetic_repository: $synthetic_repo,
    synthetic_tag: $synthetic_tag,
    manifest_digest: $manifest_digest,
    api_probe: {
      outcome: $api_outcome,
      manifest_by_digest_byte_identical: $api_manifest_digest_ok,
      manifest_by_tag_byte_identical: $api_manifest_tag_ok,
      config_byte_identical: $api_config_ok,
      all_layer_digests_ok: $api_layers_ok,
      all_parts_extracted_ok: $api_parts_ok,
      layer_verification: $layer_verification
    },
    crane_probe: {
      available: $crane_available,
      version: $crane_version,
      outcome: $crane_outcome,
      manifest_byte_identical: $crane_manifest_byte_identical,
      manifest_media_type: $crane_manifest_media_type,
      manifest_conversion: $crane_manifest_conversion,
      config_byte_identical: $crane_config_byte_identical,
      export_has_all_parts: $crane_export_has_all_parts,
      all_layer_descriptors_and_bytes_verified: $crane_layers_verified
    },
    skopeo_probe: {
      available: $skopeo_available,
      version: $skopeo_version,
      outcome: $skopeo_outcome,
      manifest_byte_identical: $skopeo_manifest_byte_identical,
      manifest_media_type: $skopeo_manifest_media_type,
      manifest_conversion: $skopeo_manifest_conversion,
      config_byte_identical: $skopeo_config_byte_identical,
      all_layer_descriptors_and_bytes_verified: $skopeo_layers_verified
    },
    docker_probe: {
      available: $docker_available,
      version: $docker_version,
      pull_outcome: $docker_pull_outcome,
      unpack_outcome: $docker_unpack_outcome,
      runtime_outcome: $docker_runtime_outcome,
      runtime_note: $docker_runtime_note,
      local_metadata_format: $docker_metadata_format,
      local_metadata_rewrite_detected: ($docker_metadata_format == "docker-save-legacy-manifest"),
      all_saved_layer_blobs_verified: $docker_saved_layers_verified,
      runtime_required_for_gate: false
    },
    standards_client_materialized: $standards_client_materialized,
    valid_image_path: "passed",
    artifact_fallback: {considered: false, reason: "valid OCI image path passed"}}' \
  > "$source_dir/client-matrix-gate.json"

printf '\nMATERIALIZATION gate complete for run %s:\n' "$run_id"
printf '  api_probe:    %s\n' "$api_outcome"
printf '  crane_probe:  %s\n' "$crane_outcome"
printf '  skopeo_probe: %s\n' "$skopeo_outcome"
printf '  docker_probe: pull=%s unpack=%s runtime=%s\n' \
  "$docker_pull_outcome" "$docker_unpack_outcome" "$docker_runtime_outcome"
printf 'Evidence: %s/client-matrix-gate.json\n' "$source_dir"
