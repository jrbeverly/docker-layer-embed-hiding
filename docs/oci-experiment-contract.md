# OCI Semantics and Experiment Contract

## Status and decision

This document is the implementation plan and evidence contract for phase one
of the proof of concept described in [the project vision](../VISION.md). Later
work must preserve the observables defined here rather than treating a
successful push or pull as sufficient proof.

The primary path is a valid OCI image. It consists of a newly generated OCI
image config and manifest whose ordered layer descriptors reference three
payload layer blobs built and published independently. An OCI artifact is a
fallback only if the image path fails. Before using that fallback, the run must
record the rejected image config and manifest, the client and registry
versions, the exact operation, and the raw status, headers, and error body that
explain the failure.

## Architecture

Three independent source images each add one payload part in a distinct final
layer. They may have unrelated base layers. Only the three payload layers are
members of the synthetic image; none of the source base layers are.

```text
source-1:base + payload/part-1.tar layer --+
source-2:base + payload/part-2.tar layer ----+--> synthetic repository
source-3:base + payload/part-3.tar layer --+      new config + new manifest
                                                   |
                                                   v
                                         reconstructed payload + SHA-256
```

Each selected blob must become available in the fourth, synthetic repository
by a registry-supported, repository-local operation. The phase-one candidate
is a cross-repository mount within one registry. If mounting is unavailable,
the experiment may upload the already downloaded bytes unchanged, but must not
repack, recompress, or rebuild a layer. This proves byte identity at the API
boundary; it does not claim that the registry kept only one physical storage
copy.

The synthetic manifest lists the payload layers in part order and copies each
source descriptor's digest, size, and media type exactly. The new config lists
the matching DiffIDs in the same order. Applying the layers to an empty root
filesystem must yield the three archive parts needed for reconstruction.

## Specification guarantees

These are requirements of the OCI specifications, not conclusions from a
particular registry or client:

- An image manifest layer entry is a descriptor. Its required `mediaType`,
  `size`, and `digest` describe the distributed blob bytes. Image layers are
  ordered changesets: the base is index zero and later entries follow in stack
  order. See the [OCI image manifest specification][manifest-spec] and
  [descriptor specification][descriptor-spec].
- For an OCI image config, `rootfs.type` is required and must be `layers`.
  `rootfs.diff_ids` is required and ordered first-to-last. Each DiffID is the
  digest of a layer's **uncompressed tar archive**. It is therefore not
  necessarily the digest in the manifest, which commonly identifies compressed
  bytes. See the [OCI image configuration specification][config-spec].
- Distribution blob `GET` and `HEAD` requests use
  `/v2/<name>/blobs/<digest>`; `<name>` is the repository namespace. A missing
  blob returns `404`. A registry may reject a manifest whose non-subject
  descriptor refers to unavailable content, in which case it must report one
  or more `MANIFEST_BLOB_UNKNOWN` errors. See the
  [OCI Distribution specification][distribution-spec].
- Cross-repository mounting is requested with
  `POST /v2/<name>/blobs/uploads/?mount=<digest>&from=<other_name>`. A successful
  mount returns `201 Created`. If mounting is unsupported or unsuccessful, the
  registry should return `202 Accepted`, starting an upload session instead.
  Mounting is optional behavior within a registry and does not demonstrate
  reuse across registries.

## Observed tool behavior

No registry or client behavior is established by this decision record. Each
implementation run must add its observations to the run evidence with exact
tool image/version identifiers and commands. Observations apply only to those
recorded versions and must not be promoted to specification guarantees.

In particular, a tool-produced manifest must be fetched back as raw JSON and
compared with the intended manifest. Console output or a successful command is
not evidence that the tool preserved descriptors or bytes.

## Open experimental questions

The following are experiments, not facts:

- Which manifest and config validation the chosen registry performs.
- Whether a digest already present in shared registry storage is readable
  through a new repository before an explicit mount or upload.
- Whether Docker/containerd accepts and materializes the chosen minimal image
  config.
- How each tested client handles blob redirects.
- Whether any copy, push, or pull tool rewrites media types, configs, manifests,
  or layers.

Redirect behavior belongs to phase two. Phase one may record a client's normal
redirect behavior if encountered, but must not introduce a redirecting control
plane or make redirect support part of phase-one success.

## Proof contract

Every run must retain a machine-readable evidence directory plus a concise run
report. Commands that probe registry semantics must preserve the raw HTTP
status line, response headers, and error body, including unsuccessful probes.
Secrets or credentials must not be recorded.

The evidence must allow direct comparison of:

1. The original payload SHA-256 with the reconstructed payload SHA-256.
2. Each source manifest payload-layer descriptor—digest, byte size, and media
   type—with the corresponding synthetic manifest descriptor.
3. Each downloaded blob's independently calculated SHA-256 and byte size with
   its descriptor digest and size.
4. The SHA-256 of each decompressed layer tar stream with the corresponding,
   ordered config DiffID.
5. The complete set of source base-layer digests with the synthetic manifest,
   demonstrating that every source base-layer digest is absent.
6. The requested operation with the raw HTTP status, headers, and error body
   for every repository-visibility, mount, manifest-push, blob `HEAD`, and blob
   `GET` probe.

Reuse is established only when source and synthetic descriptors match, the
retrieved bytes match those descriptors, and the decompressed stream hashes
match the config DiffIDs. Registry-side deduplication is not evidence of reuse,
and neither is a successful pull by itself.

## Milestones and observable gates

Later implementation milestones are complete only when their named gate is
satisfied.

1. **PAYLOAD gate — deterministic input:** Generate the deterministic payload,
   archive it, split it into exactly three parts, and record the original
   payload digest plus the part names and sizes. Rejoining and unpacking the
   parts locally must already reproduce the original digest.
2. **SOURCE gate — independent payload layers:** Build and publish three source
   images. Retain their raw manifests and identify exactly one payload layer in
   each, recording its descriptor and DiffID independently of build history.
3. **BLOB gate — verified source bytes:** `HEAD` and `GET` every selected blob
   through its source repository. Preserve HTTP evidence and show that measured
   size and SHA-256 match the source descriptor and that the decompressed tar
   contains the expected single payload part.
4. **VISIBILITY gate — synthetic-repository availability:** Probe each digest in
   the synthetic repository before and after the selected mount or unchanged
   byte upload. Preserve all responses. Afterward, `HEAD` and `GET` through the
   synthetic repository must succeed and return bytes matching the source blob.
5. **CONFIG gate — ordered filesystem identity:** Generate a new OCI image
   config with `rootfs.type: layers`. Its three ordered DiffIDs must equal
   independently calculated SHA-256 values of the uncompressed layer tar
   streams.
6. **MANIFEST gate — exact synthetic composition:** Publish a new OCI image
   manifest containing only the new config and the three selected source layer
   descriptors in part order. Fetch it back and prove descriptor equality and
   the absence of every recorded source base-layer digest.
7. **MATERIALIZATION gate — standards-oriented retrieval:** Retrieve the
   synthetic image with the selected standard client and record its version,
   commands, output, and resulting raw manifest/config/layer identities. A
   client rewrite or rejection leaves this gate open until explained and a
   standards-oriented image path succeeds, or until the documented artifact
   fallback condition is met.
8. **RECONSTRUCTION gate — byte-for-byte result:** Extract the parts from the
   retrieved layers in order, reconstruct and unpack the archive, and show that
   the reconstructed payload SHA-256 equals the original payload SHA-256.
9. **PHASE-ONE gate — auditable proof:** Produce a run report linking all prior
   gate evidence, including failed probes. Phase one passes only if every prior
   gate passes on the valid-image path, or the image failure is recorded as
   required and gates 6–8 pass using the OCI-artifact fallback.

## Phase-one non-goals

As established in `VISION.md`, phase one does not need to demonstrate:

- A useful runnable container.
- Production registry performance.
- Authentication or private repositories.
- Garbage collection or long-term upstream blob durability.
- Multi-platform images.
- Signatures or attestations.
- Automatic discovery of reusable layers.
- Dynamic or on-demand manifest construction.
- Production CloudFront integration.


Redirect-based distribution is also excluded from phase one. A later phase may
test a minimal OCI Distribution-compatible control plane that serves manifest
and config metadata while redirecting blob requests to external locations. It
must have its own evidence contract and must not weaken the phase-one proof of
content identity and reconstruction.

[config-spec]: https://github.com/opencontainers/image-spec/blob/main/config.md
[descriptor-spec]: https://github.com/opencontainers/image-spec/blob/main/descriptor.md
[distribution-spec]: https://github.com/opencontainers/distribution-spec/blob/main/spec.md
[manifest-spec]: https://github.com/opencontainers/image-spec/blob/main/manifest.md
