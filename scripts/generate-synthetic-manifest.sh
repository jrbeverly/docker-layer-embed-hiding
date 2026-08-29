#!/bin/sh
#
# Generate and validate the synthetic OCI image config and manifest
# (CONFIG gate and offline MANIFEST validation).
#
# Reads blob-inventory.json from a completed source-blobs run and produces:
#   synthetic-config.json  — minimal OCI image config (architecture/os/rootfs)
#   synthetic-manifest.json — OCI image manifest referencing the three payload layers
#   config-gate.json        — CONFIG gate evidence
#   manifest-ready.json     — offline MANIFEST gate evidence (pending registry push)
#
# Also exercises the offline validator with a deliberate wrong size, missing
# DiffID, extra base layer, and reordered DiffID to confirm each failure is
# detected.
#
# Usage:  sh scripts/generate-synthetic-manifest.sh <run-id>
#         make synthetic-manifest RUN_ID=<run-id>

set -eu

run_id=${1:?'run_id required; pass the run ID from a completed source-blobs run'}
source_dir="artifacts/source-images/$run_id"
config_file="$source_dir/synthetic-config.json"
manifest_file="$source_dir/synthetic-manifest.json"

if [ ! -f "$source_dir/blob-inventory.json" ]; then
  printf 'error: blob-inventory.json not found at %s\n' \
    "$source_dir/blob-inventory.json" >&2
  printf 'Run "make source-blobs RUN_ID=%s" first.\n' "$run_id" >&2
  exit 1
fi

if [ -f "$config_file" ] || [ -f "$manifest_file" ]; then
  printf 'error: synthetic config/manifest already exist at %s\n' "$source_dir" >&2
  exit 1
fi

# ── Extract DiffIDs and layer descriptors from the blob inventory ────────────

diff_id_1=$(jq -r '.blobs[0].payload_layer.diff_id'    "$source_dir/blob-inventory.json")
diff_id_2=$(jq -r '.blobs[1].payload_layer.diff_id'    "$source_dir/blob-inventory.json")
diff_id_3=$(jq -r '.blobs[2].payload_layer.diff_id'    "$source_dir/blob-inventory.json")

l1_digest=$(jq -r    '.blobs[0].payload_layer.digest'    "$source_dir/blob-inventory.json")
l1_size=$(jq -r      '.blobs[0].payload_layer.size'      "$source_dir/blob-inventory.json")
l1_media_type=$(jq -r '.blobs[0].payload_layer.mediaType' "$source_dir/blob-inventory.json")

l2_digest=$(jq -r    '.blobs[1].payload_layer.digest'    "$source_dir/blob-inventory.json")
l2_size=$(jq -r      '.blobs[1].payload_layer.size'      "$source_dir/blob-inventory.json")
l2_media_type=$(jq -r '.blobs[1].payload_layer.mediaType' "$source_dir/blob-inventory.json")

l3_digest=$(jq -r    '.blobs[2].payload_layer.digest'    "$source_dir/blob-inventory.json")
l3_size=$(jq -r      '.blobs[2].payload_layer.size'      "$source_dir/blob-inventory.json")
l3_media_type=$(jq -r '.blobs[2].payload_layer.mediaType' "$source_dir/blob-inventory.json")

# ── Generate OCI image config ────────────────────────────────────────────────
# Only architecture, os, and rootfs are included.  No created timestamp, no
# config section, no history — stable bytes across runs.

jq --null-input --compact-output \
  --arg diff_id_1 "$diff_id_1" \
  --arg diff_id_2 "$diff_id_2" \
  --arg diff_id_3 "$diff_id_3" \
  '{"architecture":"amd64","os":"linux",
    "rootfs":{"type":"layers","diff_ids":[$diff_id_1,$diff_id_2,$diff_id_3]}}' \
  > "$config_file"

config_digest="sha256:$(sha256sum "$config_file" | awk '{print $1}')"
config_size=$(wc -c < "$config_file" | tr -d '[:space:]')
printf 'config:   %s  size=%s\n' "$config_digest" "$config_size"

# ── Generate OCI image manifest ──────────────────────────────────────────────
# schemaVersion 2, OCI manifest media type, config descriptor derived from the
# generated config bytes, and three payload layer descriptors in part order
# copied exactly from the blob inventory.  No base-layer descriptors.

jq --null-input --compact-output \
  --arg   config_digest  "$config_digest" \
  --argjson config_size  "$config_size" \
  --arg   l1_media_type  "$l1_media_type" \
  --arg   l1_digest      "$l1_digest" \
  --argjson l1_size      "$l1_size" \
  --arg   l2_media_type  "$l2_media_type" \
  --arg   l2_digest      "$l2_digest" \
  --argjson l2_size      "$l2_size" \
  --arg   l3_media_type  "$l3_media_type" \
  --arg   l3_digest      "$l3_digest" \
  --argjson l3_size      "$l3_size" \
  '{"schemaVersion":2,
    "mediaType":"application/vnd.oci.image.manifest.v1+json",
    "config":{"mediaType":"application/vnd.oci.image.config.v1+json",
              "digest":$config_digest,"size":$config_size},
    "layers":[
      {"mediaType":$l1_media_type,"digest":$l1_digest,"size":$l1_size},
      {"mediaType":$l2_media_type,"digest":$l2_digest,"size":$l2_size},
      {"mediaType":$l3_media_type,"digest":$l3_digest,"size":$l3_size}
    ]}' \
  > "$manifest_file"

manifest_digest="sha256:$(sha256sum "$manifest_file" | awk '{print $1}')"
manifest_size=$(wc -c < "$manifest_file" | tr -d '[:space:]')
printf 'manifest: %s  size=%s\n' "$manifest_digest" "$manifest_size"

# ── Offline validator ────────────────────────────────────────────────────────
# Validates config and manifest structurally (OCI schema) and for consistency
# with the blob inventory.  Returns 0 when all checks pass, 1 on any failure.
# Does not write to disk; safe to call with deliberately wrong inputs.

validate_config_and_manifest() {
  _cfg="$1"
  _mfst="$2"

  # OCI-aware config validation: required fields, types, and digest format.
  jq -e '
    (type == "object") and
    .architecture == "amd64" and
    .os == "linux" and
    (.rootfs | type) == "object" and
    .rootfs.type == "layers" and
    (.rootfs.diff_ids | type) == "array" and
    (.rootfs.diff_ids | length) == 3 and
    ([.rootfs.diff_ids[] | test("^sha256:[0-9a-f]{64}$")] | all)
  ' "$_cfg" > /dev/null 2>&1 || return 1

  # OCI-aware manifest validation: required fields and descriptor constraints
  # from the image manifest and content descriptor specifications.
  jq -e '
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def size: type == "number" and . >= 0 and . == floor;
    def descriptor:
      (type == "object") and
      (.mediaType | type) == "string" and
      (.mediaType | length) > 0 and
      (.digest | digest) and
      (.size | size);
    (type == "object") and
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    (.config | descriptor) and
    .config.mediaType == "application/vnd.oci.image.config.v1+json" and
    (.layers | type) == "array" and
    (.layers | length) == 3 and
    (.layers | map(descriptor) | all)
  ' "$_mfst" > /dev/null 2>&1 || return 1

  # Config descriptor: actual digest and size must match the manifest entry.
  _actual_digest="sha256:$(sha256sum "$_cfg" | awk '{print $1}')"
  _actual_size=$(wc -c < "$_cfg" | tr -d '[:space:]')
  _desc_digest=$(jq -r '.config.digest' "$_mfst")
  _desc_size=$(jq -r '.config.size' "$_mfst")
  [ "$_actual_digest" = "$_desc_digest" ] || return 1
  [ "$_actual_size"   = "$_desc_size"   ] || return 1

  # DiffIDs must equal the inventory DiffIDs in part order.
  _i=0
  while [ "$_i" -lt 3 ]; do
    _exp_diff_id=$(jq -r ".blobs[$_i].payload_layer.diff_id" \
      "$source_dir/blob-inventory.json")
    _cfg_diff_id=$(jq -r ".rootfs.diff_ids[$_i]" "$_cfg")
    [ "$_exp_diff_id" = "$_cfg_diff_id" ] || return 1
    _i=$((_i + 1))
  done

  # Layer descriptors must equal the inventory descriptors in part order.
  _i=0
  while [ "$_i" -lt 3 ]; do
    _exp_digest=$(jq -r ".blobs[$_i].payload_layer.digest"    "$source_dir/blob-inventory.json")
    _exp_size=$(jq -r   ".blobs[$_i].payload_layer.size"      "$source_dir/blob-inventory.json")
    _exp_mt=$(jq -r     ".blobs[$_i].payload_layer.mediaType" "$source_dir/blob-inventory.json")
    _layer_digest=$(jq -r ".layers[$_i].digest"    "$_mfst")
    _layer_size=$(jq -r   ".layers[$_i].size"      "$_mfst")
    _layer_mt=$(jq -r     ".layers[$_i].mediaType" "$_mfst")
    [ "$_exp_digest" = "$_layer_digest" ] || return 1
    [ "$_exp_size"   = "$_layer_size"   ] || return 1
    [ "$_exp_mt"     = "$_layer_mt"     ] || return 1
    _i=$((_i + 1))
  done

  # No known base-layer digest may appear among the synthetic manifest layers.
  _manifest_digests=$(jq -r '.layers[].digest' "$_mfst")
  _base_digests=$(jq -r '.blobs[].base_layer_digests[]' \
    "$source_dir/blob-inventory.json" 2>/dev/null) || true
  for _base in $_base_digests; do
    for _mfst_layer in $_manifest_digests; do
      [ "$_base" != "$_mfst_layer" ] || return 1
    done
  done

  return 0
}

# ── Validate the generated config and manifest ───────────────────────────────

printf '\nValidating offline...\n'
if ! validate_config_and_manifest "$config_file" "$manifest_file"; then
  printf 'error: offline validation failed\n' >&2
  exit 1
fi
printf '  config and manifest: valid\n'

# ── Deliberate wrong tests ───────────────────────────────────────────────────

temporary=$(mktemp -d "$source_dir/manifest-validate.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

printf '\nDeliberate wrong tests...\n'

# Test 1: wrong size — manifest config.size incremented by one.
_wrong_mfst="$temporary/wrong-size.manifest.json"
jq --compact-output '.config.size += 1' "$manifest_file" > "$_wrong_mfst"
if validate_config_and_manifest "$config_file" "$_wrong_mfst" 2>/dev/null; then
  printf 'error: wrong-size test was NOT detected\n' >&2
  exit 1
fi
printf '  wrong-size:        detected\n'

# Test 2: missing DiffID — config diff_ids trimmed to two entries; manifest
# config descriptor updated to match the wrong config bytes so that only the
# DiffID count check fires.
_missing_cfg="$temporary/missing-diffid.config.json"
jq --compact-output 'del(.rootfs.diff_ids[2])' "$config_file" > "$_missing_cfg"
_md="sha256:$(sha256sum "$_missing_cfg" | awk '{print $1}')"
_ms=$(wc -c < "$_missing_cfg" | tr -d '[:space:]')
_missing_mfst="$temporary/missing-diffid.manifest.json"
jq --compact-output --arg d "$_md" --argjson s "$_ms" \
  '.config.digest = $d | .config.size = $s' "$manifest_file" > "$_missing_mfst"
if validate_config_and_manifest "$_missing_cfg" "$_missing_mfst" 2>/dev/null; then
  printf 'error: missing-DiffID test was NOT detected\n' >&2
  exit 1
fi
printf '  missing-DiffID:    detected\n'

# Test 3: extra base layer — prepend an inventoried source base descriptor.
# The validator must reject it before descriptor comparison because a synthetic
# manifest contains exactly the three payload layers.
_base_digest=$(jq -r '[.blobs[].base_layer_digests[]][0]' \
  "$source_dir/blob-inventory.json")
if [ "$_base_digest" = "null" ]; then
  printf 'error: extra-base-layer test requires an inventoried base layer\n' >&2
  exit 1
fi
_extra_base_mfst="$temporary/extra-base-layer.manifest.json"
jq --compact-output --arg digest "$_base_digest" \
  '.layers = [{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip",
               "digest":$digest,"size":1}] + .layers' \
  "$manifest_file" > "$_extra_base_mfst"
if validate_config_and_manifest "$config_file" "$_extra_base_mfst" 2>/dev/null; then
  printf 'error: extra-base-layer test was NOT detected\n' >&2
  exit 1
fi
printf '  extra-base-layer: detected\n'

# Test 4: reordered DiffIDs — first and last diff_ids swapped; manifest
# config descriptor updated to match the reordered config bytes so that only
# the DiffID order check fires.
_reordered_cfg="$temporary/reordered.config.json"
jq --compact-output \
  '.rootfs.diff_ids = [.rootfs.diff_ids[2],.rootfs.diff_ids[1],.rootfs.diff_ids[0]]' \
  "$config_file" > "$_reordered_cfg"
_rd="sha256:$(sha256sum "$_reordered_cfg" | awk '{print $1}')"
_rs=$(wc -c < "$_reordered_cfg" | tr -d '[:space:]')
_reordered_mfst="$temporary/reordered.manifest.json"
jq --compact-output --arg d "$_rd" --argjson s "$_rs" \
  '.config.digest = $d | .config.size = $s' "$manifest_file" > "$_reordered_mfst"
if validate_config_and_manifest "$_reordered_cfg" "$_reordered_mfst" 2>/dev/null; then
  printf 'error: reordered-DiffID test was NOT detected\n' >&2
  exit 1
fi
printf '  reordered-DiffID:  detected\n'

printf 'All deliberate wrong tests detected failures as expected.\n'

# ── Gate evidence ────────────────────────────────────────────────────────────

jq --null-input \
  --arg  run_id        "$run_id" \
  --arg  config_digest "$config_digest" \
  --argjson config_size "$config_size" \
  --arg  diff_id_1     "$diff_id_1" \
  --arg  diff_id_2     "$diff_id_2" \
  --arg  diff_id_3     "$diff_id_3" \
  '{schema_version: 1, run_id: $run_id, gate: "CONFIG",
    config_digest: $config_digest, config_size: $config_size,
    diff_ids: [$diff_id_1, $diff_id_2, $diff_id_3],
    validation: {
      oci_schema: true,
      config_descriptor_digest: true,
      config_descriptor_size: true,
      diff_ids_match_inventory: true,
      deliberate_wrong_tests: {
        wrong_size_detected:       true,
        missing_diffid_detected:   true,
        extra_base_layer_detected: true,
        reordered_diffid_detected: true}}}' \
  > "$source_dir/config-gate.json"

jq --null-input \
  --arg  run_id          "$run_id" \
  --arg  manifest_digest "$manifest_digest" \
  --argjson manifest_size "$manifest_size" \
  --slurpfile manifest   "$manifest_file" \
  '{schema_version: 1, run_id: $run_id, gate: "MANIFEST_READY",
    manifest_digest: $manifest_digest, manifest_size: $manifest_size,
    manifest: $manifest[0],
    validation: {
      oci_schema: true,
      layer_count: 3,
      layer_descriptors_match_inventory: true,
      no_base_layer_digests: true}}' \
  > "$source_dir/manifest-ready.json"

printf '\nGenerated and validated for run %s:\n' "$run_id"
printf '  synthetic-config.json   digest=%s size=%s\n' "$config_digest" "$config_size"
printf '  synthetic-manifest.json digest=%s size=%s\n' "$manifest_digest" "$manifest_size"
printf 'Evidence: %s/config-gate.json\n' "$source_dir"
printf 'Evidence: %s/manifest-ready.json\n' "$source_dir"
