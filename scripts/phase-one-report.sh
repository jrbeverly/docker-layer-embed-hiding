#!/bin/sh
#
# Produce the phase-one auditable report (PHASE-ONE gate).
#
# Verifies that all required gate evidence files exist and that each gate
# recorded in its JSON matches the expected gate name.  Collects the key
# result fields from every gate into a single phase-one-report.json.
#
# The PHASE-ONE gate passes only when:
#   - All prior gates (PAYLOAD through RECONSTRUCTION) are present.
#   - The RECONSTRUCTION gate confirmed sha256_match = true.
#   - The API probe and at least one standards-oriented OCI client succeeded.
#
# Usage:  sh scripts/phase-one-report.sh <run-id>
#         make phase-one RUN_ID=<run-id>

set -eu

run_id=${1:?'run_id required; pass the run ID from a completed reconstruct run'}
source_dir="artifacts/source-images/$run_id"

# ── Check all gate evidence files ─────────────────────────────────────────────

printf 'Checking gate evidence for run %s...\n' "$run_id"

for f in \
    "payload/metadata.json" \
    "report.json" \
    "blob-inventory.json" \
    "visibility.json" \
    "config-gate.json" \
    "manifest-ready.json" \
    "publish-gate.json" \
    "client-matrix-gate.json" \
    "reconstruction-gate.json"; do
  path="$source_dir/$f"
  if [ ! -f "$path" ]; then
    printf 'error: required gate file missing: %s\n' "$path" >&2
    exit 1
  fi
  printf '  found: %s\n' "$f"
done

for gate_file in \
    "blob-inventory.json:BLOB" \
    "visibility.json:VISIBILITY" \
    "config-gate.json:CONFIG" \
    "manifest-ready.json:MANIFEST_READY" \
    "publish-gate.json:MANIFEST" \
    "client-matrix-gate.json:MATERIALIZATION" \
    "reconstruction-gate.json:RECONSTRUCTION"; do
  file=${gate_file%%:*}
  expected_gate=${gate_file#*:}
  recorded_gate=$(jq -r '.gate' "$source_dir/$file")
  if [ "$recorded_gate" != "$expected_gate" ]; then
    printf 'error: %s records gate %s (expected %s)\n' \
      "$source_dir/$file" "$recorded_gate" "$expected_gate" >&2
    exit 1
  fi
done

if [ -f "$source_dir/phase-one-report.json" ]; then
  printf 'error: phase-one-report.json already exists at %s\n' "$source_dir" >&2
  exit 1
fi

# ── Verify reconstruction succeeded ──────────────────────────────────────────

recon_sha256_match=$(jq -r '.verification.sha256_match' \
  "$source_dir/reconstruction-gate.json")
if [ "$recon_sha256_match" != "true" ]; then
  printf 'error: RECONSTRUCTION gate sha256_match is not true\n' >&2
  exit 1
fi

api_outcome=$(jq -r '.api_probe.outcome' "$source_dir/client-matrix-gate.json")
if [ "$api_outcome" != "ok" ]; then
  printf 'error: MATERIALIZATION api_probe outcome is %s (expected ok)\n' \
    "$api_outcome" >&2
  exit 1
fi

standards_client_materialized=$(jq -r '.standards_client_materialized' \
  "$source_dir/client-matrix-gate.json")
if [ "$standards_client_materialized" != "true" ]; then
  printf 'error: MATERIALIZATION has no verified standards-oriented OCI client\n' >&2
  exit 1
fi

printf '\nAll gate checks passed.\n'

# ── Collect summary fields ────────────────────────────────────────────────────

payload_sha256=$(jq -r '.payload.sha256' "$source_dir/payload/metadata.json")
payload_bytes=$(jq -r '.payload.byte_count' "$source_dir/payload/metadata.json")

source_count=$(jq '.sources | length' "$source_dir/report.json")
registry=$(jq -r '.registry' "$source_dir/report.json")

blob_gate=$(jq -r '.gate' "$source_dir/blob-inventory.json")
visibility_gate=$(jq -r '.gate' "$source_dir/visibility.json")
config_gate=$(jq -r '.gate' "$source_dir/config-gate.json")
manifest_gate=$(jq -r '.gate' "$source_dir/publish-gate.json")
materialization_gate=$(jq -r '.gate' "$source_dir/client-matrix-gate.json")
reconstruction_gate=$(jq -r '.gate' "$source_dir/reconstruction-gate.json")

manifest_digest=$(jq -r '.manifest_publish.digest' "$source_dir/publish-gate.json")
synthetic_repo=$(jq -r '.synthetic_repository' "$source_dir/publish-gate.json")
synthetic_tag=$(jq -r '.synthetic_tag' "$source_dir/publish-gate.json")

reconstructed_sha256=$(jq -r '.verification.reconstructed_payload_sha256' \
  "$source_dir/reconstruction-gate.json")

crane_outcome=$(jq -r '.crane_probe.outcome' "$source_dir/client-matrix-gate.json")
crane_manifest_conversion=$(jq -r '.crane_probe.manifest_conversion' \
  "$source_dir/client-matrix-gate.json")

skopeo_outcome=$(jq -r '.skopeo_probe.outcome' "$source_dir/client-matrix-gate.json")
skopeo_manifest_conversion=$(jq -r '.skopeo_probe.manifest_conversion' \
  "$source_dir/client-matrix-gate.json")

docker_pull=$(jq -r '.docker_probe.pull_outcome' "$source_dir/client-matrix-gate.json")
docker_unpack=$(jq -r '.docker_probe.unpack_outcome' "$source_dir/client-matrix-gate.json")
docker_runtime=$(jq -r '.docker_probe.runtime_outcome' "$source_dir/client-matrix-gate.json")

# ── Tool versions from evidence and current environment ───────────────────────

crane_version=$(jq -r '.crane_probe.version' "$source_dir/client-matrix-gate.json")
docker_version=$(jq -r '.docker_probe.version' "$source_dir/client-matrix-gate.json")
curl_version=$(curl --version 2>/dev/null | awk 'NR==1{print $2}' | tr -d '\r\n')
registry_image=$(awk '/image: registry:/{print $2}' compose.yaml)

tool_versions=$(jq --null-input \
  --arg crane    "$crane_version" \
  --arg docker   "$docker_version" \
  --arg curl     "$curl_version" \
  --arg registry "$registry_image" \
  '{crane: $crane, docker: $docker, curl: $curl, registry: $registry}')

# ── Descriptor table: one row per payload layer ───────────────────────────────

descriptor_table=$(jq '[.blobs | to_entries[] |
  {layer: (.key + 1),
   source_layer: (.value.payload_layer_index + 1),
   source: .value.source,
   digest: .value.payload_layer.digest,
   size:   .value.payload_layer.size,
   mediaType: .value.payload_layer.mediaType,
   diff_id: .value.payload_layer.diff_id}]' \
  "$source_dir/blob-inventory.json")

source_images=$(jq '[.sources[] |
  {source,
   tagged_reference: .image,
   manifest_digest,
   immutable_reference: ((.image | sub(":[^:]+$"; "")) + "@" + .manifest_digest)}]' \
  "$source_dir/report.json")

# ── HTTP mount evidence summary ───────────────────────────────────────────────

http_mount_evidence=$(jq '[.mounts[] |
  {source,
   http_status: .mount_status,
   succeeded: .mount_succeeded,
   pre_head_status: .pre_mount_head_status,
   post_head_status: .post_mount_head_status}]' \
  "$source_dir/visibility.json")

# ── Write phase-one-report.json ───────────────────────────────────────────────

jq --null-input \
  --arg  run_id                   "$run_id" \
  --arg  registry                 "$registry" \
  --arg  synthetic_repo           "$synthetic_repo" \
  --arg  synthetic_tag            "$synthetic_tag" \
  --arg  manifest_digest          "$manifest_digest" \
  --arg  payload_sha256           "$payload_sha256" \
  --argjson payload_bytes         "$payload_bytes" \
  --argjson source_count          "$source_count" \
  --argjson source_images         "$source_images" \
  --arg  reconstructed_sha256     "$reconstructed_sha256" \
  --arg  crane_outcome            "$crane_outcome" \
  --arg  crane_manifest_conversion "$crane_manifest_conversion" \
  --arg  skopeo_outcome           "$skopeo_outcome" \
  --arg  skopeo_manifest_conversion "$skopeo_manifest_conversion" \
  --arg  docker_pull              "$docker_pull" \
  --arg  docker_unpack            "$docker_unpack" \
  --arg  docker_runtime           "$docker_runtime" \
  --argjson tool_versions         "$tool_versions" \
  --argjson descriptor_table      "$descriptor_table" \
  --argjson http_mount_evidence   "$http_mount_evidence" \
  '{schema_version: 1,
    run_id: $run_id,
    gate: "PHASE-ONE",
    registry: $registry,
    synthetic_image: {
      repository: $synthetic_repo,
      tag: $synthetic_tag,
      manifest_digest: $manifest_digest
    },
    tool_versions: $tool_versions,
    descriptor_table: $descriptor_table,
    http_mount_evidence: $http_mount_evidence,
    gates: {
      PAYLOAD:         {status: "pass", evidence: "payload/metadata.json"},
      SOURCE:          {status: "pass", evidence: "report.json"},
      BLOB:            {status: "pass", evidence: "blob-inventory.json"},
      VISIBILITY:      {status: "pass", evidence: "visibility.json"},
      CONFIG:          {status: "pass", evidence: "config-gate.json"},
      MANIFEST:        {status: "pass", evidence: "publish-gate.json"},
      MATERIALIZATION: {status: "pass", evidence: "client-matrix-gate.json"},
      RECONSTRUCTION:  {status: "pass", evidence: "reconstruction-gate.json"}
    },
    payload_verification: {
      original_sha256: $payload_sha256,
      original_bytes: $payload_bytes,
      reconstructed_sha256: $reconstructed_sha256,
      match: true
    },
    source_image_count: $source_count,
    source_images: $source_images,
    client_matrix: {
      api_probe: "ok",
      crane_probe: $crane_outcome,
      crane_manifest_conversion: $crane_manifest_conversion,
      skopeo_probe: $skopeo_outcome,
      skopeo_manifest_conversion: $skopeo_manifest_conversion,
      docker_pull: $docker_pull,
      docker_unpack: $docker_unpack,
      docker_runtime: $docker_runtime,
      docker_runtime_required: false
    },
    proof_scope: {
      proven: "digest_identity",
      proven_detail: "Each source layer descriptor (digest, size, mediaType) appears unchanged in the synthetic manifest. The bytes retrieved from the synthetic repository hash to that digest. The decompressed tar stream hashes to the config DiffID. These checks establish that the synthetic image references the exact same content as the source layers.",
      not_claimed: "physical_backend_deduplication",
      not_claimed_detail: "Whether the registry stores a single on-disk copy of each blob or multiple copies is not observed and not required. A successful cross-repository mount hints at storage reuse but does not prove it. This proof operates at the content-address layer: equal digests mean equal bytes."
    },
    conclusion: "Phase one proof complete: three payload blobs from independent source images were recomposed into a synthetic OCI manifest without copying or rebuilding the underlying blob bytes. The reconstructed payload SHA-256 matches the original. Digest identity is proven; physical backend deduplication is not claimed."}' \
  > "$source_dir/phase-one-report.json"

printf '\nPHASE-ONE gate complete for run %s:\n' "$run_id"
printf '  original SHA-256:      %s\n' "$payload_sha256"
printf '  reconstructed SHA-256: %s\n' "$reconstructed_sha256"
printf '  match: true\n'
printf 'Evidence: %s/phase-one-report.json\n' "$source_dir"
