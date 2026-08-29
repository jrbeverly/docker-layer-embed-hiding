# Controlled payload layer

`make layer` creates a deterministic OCI gzip layer containing one tar entry:
`payload/archive.part1`. GNU tar fixes its format, path, UID, GID, mode, mtime,
and ordering; `gzip -n -9` removes the gzip timestamp and original filename.
The declared media type is
`application/vnd.oci.image.layer.v1.tar+gzip`.

The identities have deliberately separate meanings:

```sh
# Manifest descriptor digest and size: compressed distribution bytes.
sha256sum artifacts/layer/layer.tar.gz
wc -c <artifacts/layer/layer.tar.gz

# Config rootfs.diff_ids entry: uncompressed tar stream.
gzip -dc artifacts/layer/layer.tar.gz | sha256sum

# The controlled archive has exactly one entry.
tar -tf artifacts/layer/layer.tar
```

`make layer-validate` repeats the controlled generation and builds the
`fixtures/source-1` image twice as OCI archives. It independently measures the
builder layer's compressed digest, size, and uncompressed DiffID and writes
`artifacts/layer-validation-report.json`.

BuildKit does not serialize the same tar as the hand-controlled generator: its
`COPY` layer includes an explicit `payload/` directory entry and build-context
timestamps. The validation therefore checks that the only regular file is the
intended payload and records whether two clean builds reproduce the descriptor
and DiffID. When publishing the source image, the exported/registry blob and
its independently measured values are authoritative. Exact equality with the
hand-controlled tar is not required for the central reuse proof; exact reuse
of the selected published blob is.

Source publication does not infer the payload layer from instruction or
manifest order. It downloads every candidate layer descriptor from the
registry, decompresses and inspects each tar stream, and requires exactly one
candidate whose only regular entry is the expected payload path and whose file
hash matches the pre-OCI part. The selected manifest index then identifies the
corresponding ordered `rootfs.diff_ids` entry in the downloaded image config.
