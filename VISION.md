# Vision: Synthetic OCI Archive From Distributed Layers

## Objective

Determine whether OCI container distribution can be used to construct and distribute a synthetic archive whose constituent pieces originate as layers of otherwise independent container images.

The proof of concept should demonstrate the complete flow locally using an OCI-compatible registry and standard container/OCI tooling such as `crane`, `skopeo`, `oras`, Docker, or equivalent tools.

The experiment is intentionally small and static. We are proving that the mechanism works, not building a production service.

## Core Hypothesis

OCI image layers are independently content-addressed blobs.

A layer does not cryptographically depend on the layer that preceded it in the image where it originally appeared. The ordering and composition of layers is defined by the image manifest.

Therefore, it should be possible to:

1. Create a payload.
2. Compress and split that payload into three pieces.
3. Place each piece into a separate OCI image layer.
4. Publish those source images to an OCI registry.
5. Identify the digest and metadata of each payload-containing layer.
6. Construct a new synthetic OCI image whose three layers reference those existing blobs.
7. Generate whatever OCI config and manifest metadata is necessary to make the synthetic image internally consistent.
8. Pull or otherwise materialize the synthetic image using standard OCI tooling.
9. Extract the three pieces from the resulting layers/filesystem.
10. Reassemble the original compressed archive.
11. Recover the original payload and verify it byte-for-byte.

Success demonstrates that independently published OCI blobs can be recomposed into a new OCI object without rebuilding or modifying those blobs.

---

## Conceptual Flow

Start with approximately 3 MB of deterministic synthetic data:

```text
payload.bin
    |
    | compress + split
    v
archive.part1
archive.part2
archive.part3
```

The exact archive format is not important.

Use whichever format provides the simplest deterministic split/archive workflow available in the environment, for example:

* split tar archive
* 7-Zip volumes
* another simple multipart archive format

The only requirement is that the three pieces can later be recombined to recover `payload.bin` exactly.

---

## Source Images

Create three independent source images.

Each image should contain exactly one archive piece in a clearly identifiable layer.

Conceptually:

```text
source-image-1
    |
    +-- arbitrary base image/layers
    |
    +-- payload layer
        /payload/archive.part1


source-image-2
    |
    +-- different/arbitrary base image/layers
    |
    +-- payload layer
        /payload/archive.part2


source-image-3
    |
    +-- different/arbitrary base image/layers
    |
    +-- payload layer
        /payload/archive.part3
```

The source images may use different base images to make the experiment explicit.

For example:

```text
source-image-1 -> Alpine
source-image-2 -> Python
source-image-3 -> another arbitrary base
```

The base images are not part of the data we ultimately want.

They exist to demonstrate that the payload layers can originate from unrelated images and subsequently be reused independently.

---

## Local Registry

Run an OCI-compatible registry locally as a container.

The simplest suitable registry should be preferred.

Candidates include:

* CNCF Distribution / `registry:2`
* Harbor
* another OCI Distribution-compatible registry

A full Harbor installation is unnecessary unless it provides something specifically required by the experiment.

The registry should contain:

```text
localhost:<port>/poc/source-1
localhost:<port>/poc/source-2
localhost:<port>/poc/source-3
localhost:<port>/poc/synthetic
```

All source images must be pushed to the registry before constructing the synthetic image.

---

## Discovering the Payload Blobs

After publishing the three source images, inspect their manifests.

For each source image, identify the layer corresponding to the operation that introduced its archive piece.

Record at minimum:

```text
Source image
Layer digest
Layer compressed size
Layer media type
Uncompressed layer digest / diff_id, if required
```

For example:

```text
archive.part1 -> sha256:AAA...
archive.part2 -> sha256:BBB...
archive.part3 -> sha256:CCC...
```

The experiment should verify that these blobs can be independently retrieved through the registry's blob API.

Conceptually:

```text
GET /v2/poc/source-1/blobs/sha256:AAA
GET /v2/poc/source-2/blobs/sha256:BBB
GET /v2/poc/source-3/blobs/sha256:CCC
```

Each downloaded blob should be independently inspectable as an OCI layer archive.

---

## Synthetic Image

Construct a new OCI image without rebuilding the three payload layers.

Its manifest should reference the three existing layer blobs:

```text
synthetic
    |
    +-- new config
    |
    +-- sha256:AAA  -> archive.part1
    |
    +-- sha256:BBB  -> archive.part2
    |
    +-- sha256:CCC  -> archive.part3
```

The manifest should order the layers as:

```text
part1
part2
part3
```

No Alpine, Python, or other source-image base layers should be present in the synthetic image.

The synthetic image should therefore logically produce a filesystem resembling:

```text
/
└── payload/
    ├── archive.part1
    ├── archive.part2
    └── archive.part3
```

---

## OCI Config

Prefer constructing a **valid OCI image**, rather than deliberately relying on malformed metadata.

Generate a new config blob appropriate for the synthetic image.

Its `rootfs.diff_ids` should correspond to the uncompressed digests of the three selected layer blobs, in the same order as the manifest:

```json
{
  "architecture": "amd64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:<part1-uncompressed-digest>",
      "sha256:<part2-uncompressed-digest>",
      "sha256:<part3-uncompressed-digest>"
    ]
  }
}
```

Additional minimum-required OCI config fields may be added as necessary.

The resulting config itself becomes another content-addressed blob and its digest is referenced from the synthetic manifest.

If creating a fully valid runnable image introduces unnecessary complexity, the experiment may fall back to treating the result as an OCI artifact that can be copied/materialized by lower-level OCI tooling.

However, producing a valid OCI image is the preferred outcome.

---

## Blob Reuse

An important part of the experiment is proving that the payload blobs are **reused**, not regenerated.

The synthetic image must reference exactly:

```text
sha256:AAA
sha256:BBB
sha256:CCC
```

from the source images.

Do not extract each archive piece and create three new layer archives for the synthetic image.

The selected layer bytes must remain unchanged.

The synthetic manifest and config may be newly generated.

---

## Registry Blob Visibility

A practical implementation detail must be investigated during the POC.

OCI Distribution exposes blobs through repository-scoped URLs:

```text
/v2/<repository>/blobs/<digest>
```

The experiment must determine what is necessary for the three source blobs to become retrievable through the synthetic repository.

Possible approaches include:

1. Cross-repository blob mounting through the OCI Distribution API.
2. Registry-native deduplication/content-addressed storage behavior.
3. Explicitly mounting/linking the existing blobs into the synthetic repository.
4. Other standards-compliant mechanisms supported by the selected registry.

The important invariant is:

**The underlying blob bytes must not be regenerated.**

---

## Pull / Materialization Test

Once the synthetic manifest has been published:

```text
localhost:<port>/poc/synthetic:latest
```

attempt to retrieve it using progressively lower-level tooling.

Preferred test order:

```text
docker / podman
        |
        v
crane / skopeo
        |
        v
oras or direct OCI Distribution API
```

Failure of Docker to run the image does not automatically invalidate the experiment.

The fundamental success criterion is that a standards-oriented OCI client can resolve the manifest and retrieve all referenced blobs.

---

## Reconstruction

After retrieving the synthetic object, recover:

```text
archive.part1
archive.part2
archive.part3
```

Reassemble them:

```text
archive.part1 +
archive.part2 +
archive.part3
        |
        v
original compressed archive
        |
        v
payload.bin
```

Calculate a digest of `payload.bin` before the experiment:

```text
SHA256(original payload.bin)
```

and after reconstruction:

```text
SHA256(reconstructed payload.bin)
```

They MUST match.

This is the definitive data-integrity test.

---

## Phase Two: Redirect Registry

The initial POC does **not** need to implement redirects.

First prove:

```text
independent images
        ↓
independent OCI blobs
        ↓
synthetic manifest
        ↓
synthetic OCI object
        ↓
materialization
        ↓
archive reconstruction
```

Once that works, extend the experiment with a minimal OCI Distribution-compatible control plane.

Instead of serving payload blobs itself:

```text
GET /v2/poc/synthetic/blobs/sha256:AAA
```

the control plane would return:

```text
HTTP 307
Location: <external OCI blob URL>
```

This allows the architecture to become:

```text
                  Synthetic Registry
                         |
                  manifest + config
                         |
              +----------+----------+
              |          |          |
             307        307        307
              |          |          |
              v          v          v
          Registry A Registry B Registry C
              |          |          |
            part1      part2      part3
```

The external registries could eventually be public registries such as Docker Hub, GitHub Container Registry, Quay, or ordinary object/CDN storage.

This phase should only be attempted after local blob recomposition is proven.

The concrete local topology, read-only endpoint contract, client and failure
matrix, and evidence requirements are defined in the
[local redirect control plane experiment](docs/local-redirect-control-plane.md).

---

## Tooling

Use whatever combination minimizes custom implementation.

Likely useful tools:

```text
Docker / Podman
crane
skopeo
oras
curl
jq
tar / 7z / split
sha256sum
```

Direct HTTP requests against the OCI Distribution API are acceptable and may be preferable when testing exact registry semantics.

Avoid writing a custom registry until the underlying OCI behavior has been demonstrated.

---

## Success Criteria

The POC succeeds if all of the following are demonstrated:

1. A deterministic payload is created and its SHA-256 recorded.
2. The payload is compressed/split into three pieces.
3. Three unrelated source images each introduce one piece in a distinct layer.
4. All three images are pushed to a local OCI registry.
5. The three exact payload layer blobs are identified.
6. Each layer blob can be independently retrieved and inspected.
7. A new synthetic manifest is created referencing those exact three blobs.
8. No source-image base layers are included.
9. A suitable synthetic OCI config is generated.
10. The synthetic object is successfully published.
11. Standard OCI tooling can retrieve/materialize its three layers.
12. The three archive pieces are recovered.
13. The archive is reconstructed.
14. The resulting payload has exactly the same SHA-256 as the original.

A subsequent phase succeeds if the same process works while the synthetic registry responds to blob requests with redirects to external blob locations.

---

## Non-Goals

This POC does not need to demonstrate:

* a useful runnable container
* production registry performance
* authentication
* private repositories
* garbage collection
* long-term upstream blob durability
* multi-platform images
* signatures or attestations
* automatic discovery of reusable layers
* dynamic/on-demand manifest construction
* production CloudFront integration

Those concerns can be evaluated after the fundamental OCI composition mechanism has been proven.

---

## Ultimate Question

The experiment exists to answer one question:

> Can an OCI manifest act as a synthetic composition of independently created, content-addressed filesystem layers, allowing a payload distributed across those layers to be retrieved and reconstructed without copying or rebuilding the original layer blobs?

If the local experiment succeeds, the next question is:

> Can those same blob references be resolved through a lightweight OCI control plane that redirects each blob request to an existing external registry or object store?

A successful result would establish the technical basis for a registry that owns primarily **metadata and composition**, while the bulk content remains distributed across independent OCI-compatible storage locations.
