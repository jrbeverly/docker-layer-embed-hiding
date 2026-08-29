#!/bin/sh

set -eu

payload_directory=${1:-artifacts/payload}
output_directory=${2:-artifacts/layer}
source_part="$payload_directory/archive.part-01"
layer_tar="$output_directory/layer.tar"
layer_gzip="$output_directory/layer.tar.gz"
metadata="$output_directory/metadata.json"
media_type='application/vnd.oci.image.layer.v1.tar+gzip'

if [ ! -f "$source_part" ]; then
  printf 'error: payload part not found at %s; run make payload first\n' "$source_part" >&2
  exit 1
fi

mkdir -p "$output_directory"
if [ -e "$layer_tar" ] || [ -e "$layer_gzip" ] || [ -e "$metadata" ]; then
  printf 'error: layer output already exists in %s\n' "$output_directory" >&2
  exit 1
fi

staging=$(mktemp -d "$output_directory/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
mkdir -p "$staging/payload"
cp "$source_part" "$staging/payload/archive.part1"
chmod 0644 "$staging/payload/archive.part1"

tar --format=ustar --sort=name --mtime='@0' --owner=0 --group=0 \
  --numeric-owner --mode='0644' -cf "$layer_tar" \
  -C "$staging" payload/archive.part1
gzip -n -9 -c "$layer_tar" >"$layer_gzip"

descriptor_digest=$(sha256sum "$layer_gzip" | awk '{print $1}')
descriptor_size=$(wc -c <"$layer_gzip" | tr -d '[:space:]')
diff_id=$(sha256sum "$layer_tar" | awk '{print $1}')

jq --null-input \
  --arg media_type "$media_type" \
  --arg digest "sha256:$descriptor_digest" \
  --arg diff_id "sha256:$diff_id" \
  --argjson size "$descriptor_size" \
  '{
    schema_version: 1,
    path: "payload/archive.part1",
    normalization: {uid: 0, gid: 0, mode: "0644", mtime: 0, format: "ustar"},
    descriptor: {mediaType: $media_type, size: $size, digest: $digest},
    diff_id: $diff_id
  }' >"$metadata"

printf 'Controlled layer: %s bytes, %s\n' "$descriptor_size" "sha256:$descriptor_digest"
printf 'Uncompressed DiffID: %s\n' "sha256:$diff_id"
