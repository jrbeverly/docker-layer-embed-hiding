# Phase-one implementation plan

This plan selects the phase-one toolchain for the proof contract in
[OCI semantics and experiment contract](oci-experiment-contract.md). The
experiment will be a small POSIX shell harness. Python or Go should be added
only if exact JSON construction cannot remain clear and reliable with `jq`.

## Pinned baseline

| Tool | Selection | Responsibility |
| --- | --- | --- |
| Registry | `registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373` | Local, public/no-auth Distribution API and cross-repository mounts. The digest pins the multi-platform image index. |
| crane | `0.21.7` | Fetch raw manifests/configs and export images when the fetched bytes can be verified. |
| Docker | Engine 24+ with BuildKit and Compose v2 | Build the three deliberately unrelated source images and run the registry. It does not assemble the synthetic image. |
| curl and jq | Host/devcontainer versions | Make observable Distribution API requests and construct canonical JSON inputs. Raw status, headers, and bodies are retained. |
| tar, gzip, split, sha256sum | Host/devcontainer versions | Create deterministic data, inspect layer tar streams, split/rejoin content, and independently calculate digests. |

The `crane` installer pins upstream release archives as follows:

| Platform | SHA-256 |
| --- | --- |
| Linux x86_64 | `1a57bc98207fa1c0d04bf760699099e26f8383499bfd55b99c1b919a928a7230` |
| Linux arm64 | `b6ee979d9411dfb05ce35ab9e156fe5de7def11a230764a7856ffa2eb971fa88` |

Run `sh scripts/install-crane.sh` to install the checked binary to
`$HOME/.local/bin`, or pass another destination directory as its first
argument. Run `make tools-check` afterward. Optional comparison clients such
as `skopeo` and `oras` are intentionally not required until an experiment
names the additional evidence they provide.

## Responsibilities and byte preservation

Docker/BuildKit may create the source layers, but it must not create the
synthetic image. `crane manifest` and `crane config` are inspection tools;
their output must be saved and compared to raw Distribution API responses.
`crane export` may be used only when every resulting layer digest and size is
independently checked. Do not use `crane append`: it can construct new layer
bytes instead of publishing the already identified descriptors.

The synthetic config and manifest will be generated explicitly with `jq`,
digested with `sha256sum`, uploaded with `curl`, and then fetched back as raw
JSON. Cross-repository mounts use `curl` so the requested URL, HTTP status,
headers, and response body can be retained. If mounting returns an upload
session, the exact downloaded blob bytes may be uploaded unchanged; they must
never be unpacked and repacked or recompressed.

Generated run evidence belongs under `artifacts/`, which is ignored by Git.
Each run will use a distinct directory and retain commands, tool versions, raw
HTTP exchanges, manifests, configs, blobs, calculated digests, and the concise
gate report required by the proof contract.

## Environment and commands

The authoritative environment is the repository devcontainer. Its
Docker-in-Docker feature supplies an isolated daemon and Compose v2; port 5000
is available inside the devcontainer. From that environment:

```sh
scripts/install-crane.sh
make tools-check
make registry-up
make registry-status
make registry-down
```

Host use requires Linux, `make`, Docker Engine 24 or newer with a reachable
daemon, the Compose v2 plugin, outbound HTTPS for image/tool downloads, and an
unused TCP port 5000. The remaining required commands are reported with
actionable installation guidance by `make tools-check`. Docker Desktop users
must run these commands in a shell where `localhost:5000` reaches the published
Compose port.

## Planned implementation sequence

1. Add deterministic payload/archive generation and a local reconstruction
   check under `scripts/`, writing only to `artifacts/`.
2. Add one Dockerfile to each `fixtures/source-*` directory, with unrelated
   pinned bases and exactly one final payload layer, then publish the sources.
3. Capture source manifests and verify each selected descriptor, compressed
   blob digest/size, tar contents, and DiffID.
4. Probe synthetic-repository visibility before and after cross-repository
   mounts, retaining every raw HTTP exchange.
5. Generate and upload the config and manifest explicitly, fetch them back,
   and prove descriptor equality and base-layer exclusion.
6. Materialize the image, reconstruct the payload, compare its SHA-256, and
   produce the phase-one gate report.

## Alternatives and likely failure modes

The preferred path uses a valid OCI image and cross-repository mounts. If a
registry returns `202 Accepted` instead of completing a mount, the only allowed
fallback is to upload the already verified compressed blob bytes unchanged;
repacking or recompressing them would invalidate the reuse proof. An OCI
artifact is reserved for a documented image-path failure under the experiment
contract, not as an automatic fallback.

Common failures are a missing or wrong `crane` version, an unreachable Docker
daemon, an occupied registry port, stale registry state, an existing run ID,
mutable or unavailable fixture bases, a mount response other than `201`, a
manifest rejected with `MANIFEST_BLOB_UNKNOWN`, client manifest conversion, or
cached client content hiding a retrieval defect. Scripts fail at the violated
invariant and retain raw HTTP or client output under the run evidence directory
where applicable. Use a new run ID and `make registry-reset` when retrying a
full proof; use `make clean-artifacts` only when retained evidence is no longer
needed.

Automated checks should install the pinned toolchain and invoke `make validate`
so the same validation remains available locally.
