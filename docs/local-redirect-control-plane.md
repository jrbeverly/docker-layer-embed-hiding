# Local redirect control plane experiment

## Decision and scope

Phase two tests whether standard OCI clients can retrieve the phase-one
synthetic image when its layer bytes live behind three different HTTP origins.
The first experiment is entirely local and unauthenticated. Public registries,
object storage, CDNs, CloudFront, and their authentication models are deferred
until local client behavior has been observed and recorded.

The control plane is a minimal read-only OCI Distribution service. It owns one
static synthetic repository, manifest, and config blob. It has a static mapping
from each of the three layer digests to an absolute URL on a different local
origin. It does not accept pushes and does not implement authentication,
discovery, garbage collection, signing, dynamic composition, or tag mutation.

The baseline topology uses four isolated listeners and no shared storage:

```text
clean client content store
          |
          v
control plane (manifest + config)
  | 307             | 307             | 307
  v                 v                 v
origin 1          origin 2          origin 3
layer 1 only      layer 2 only      layer 3 only
```

Each origin must have its own port, document root, access log, and process or
container. Origin 1 must not be able to serve layers 2 or 3, and similarly for
the other origins. The control plane must not contain layer bytes. The initial
client content store must be new and empty; a separate clean store is preferred
for every client and negative case.

## Static objects and routing

Use the phase-one synthetic manifest, config, and exact compressed layer bytes.
At startup, load an immutable table containing:

```text
synthetic repository and tag
manifest bytes, digest, media type, and size
config bytes, digest, media type, and size
layer digest 1 -> http://origin-1:<port>/blobs/<digest-1>
layer digest 2 -> http://origin-2:<port>/blobs/<digest-2>
layer digest 3 -> http://origin-3:<port>/blobs/<digest-3>
```

Routing must match a complete digest string, not a prefix. The service must not
derive a target from user input or follow redirects itself. Responses should
include `Docker-Distribution-Api-Version: registry/2.0`. Error responses use
`application/json` and the Distribution error envelope.

### Required Distribution endpoints

| Request | Required behavior |
| --- | --- |
| `GET /v2/` | `200 OK`, an empty body, and `Docker-Distribution-Api-Version: registry/2.0`. |
| `HEAD /v2/` | Same status and headers as `GET`, without a body. |
| `GET /v2/poc/synthetic/manifests/<tag>` | `200 OK` with the exact synthetic manifest bytes, its OCI `Content-Type`, `Content-Length`, and `Docker-Content-Digest`. |
| `GET /v2/poc/synthetic/manifests/<manifest-digest>` | The same byte-identical manifest response. |
| `HEAD` for either manifest URL | The corresponding `GET` status and metadata headers, with no body. |
| `GET /v2/poc/synthetic/blobs/<config-digest>` | `200 OK` with the exact config bytes, OCI config `Content-Type`, `Content-Length`, and `Docker-Content-Digest`. |
| `HEAD /v2/poc/synthetic/blobs/<config-digest>` | The same metadata and status as config `GET`, with no body. |
| `GET /v2/poc/synthetic/blobs/<layer-digest>` | `307 Temporary Redirect`, zero-length body, and an absolute `Location` from the static mapping. Responses should set `Content-Length: 0` and `Cache-Control: no-store` during experiments. |
| `HEAD /v2/poc/synthetic/blobs/<layer-digest>` | The same `307` and `Location` as `GET`, with no body. A conforming redirect follower must issue `HEAD`, not `GET`, to the target. |
| Unknown repository, reference, or digest | `404 Not Found` with `NAME_UNKNOWN`, `MANIFEST_UNKNOWN`, or `BLOB_UNKNOWN` as appropriate. It must never fall through to an origin. |
| Upload, manifest mutation, and deletion routes | `405 Method Not Allowed` with an `Allow` header where the route is known; no state is changed. Catalog and tag-list discovery routes may return `404` because discovery is out of scope. |

The config is a blob in Distribution terms, so the config endpoint is required
even though the service is described as owning metadata. In the baseline the
control plane serves it directly. Redirecting the config would add no proof of
distributed layer reuse and would confound diagnosis of layer redirect support.
A later, supplementary matrix case may redirect the config to a fourth local
origin to record whether each client handles all blob descriptors uniformly;
that case is not part of the phase-two success gate.

### Origin responses

Each origin supports `GET` and `HEAD` for its one mapped path. A full `GET`
returns `200 OK`, the exact compressed layer bytes, `Content-Length`,
`Content-Type: application/octet-stream`, `ETag` containing the digest, and
`Accept-Ranges: bytes`. `HEAD` returns the same metadata without a body.

A satisfiable single byte range returns `206 Partial Content` with the exact
slice, `Content-Range`, `Content-Length`, and `Accept-Ranges: bytes`. An
unsatisfiable range returns `416 Range Not Satisfiable` with
`Content-Range: bytes */<full-size>`. Unknown paths return `404`; origins must
not use the digest-shaped URL as evidence that their response body is correct.

## Evidence contract

Every case retains the client version and command, an assertion that its
content store began empty, control-plane and origin access logs, response
status and headers for each hop, and all received bytes or their measured size
and SHA-256. Logs need a shared request ID or timestamps precise enough to
reconstruct ordering. Do not record credentials.

A positive materialization passes only when all of the following hold:

1. The manifest was fetched through the control plane and is byte-identical to
   the intended OCI manifest.
2. The config was fetched through the control plane and its digest and size
   match its descriptor.
3. Each layer request first reached the control plane and received its mapped
   `307`; the corresponding origin then served the response. Direct origin
   access alone is a failure, even if reconstruction succeeds.
4. Each final layer body independently matches the descriptor's compressed
   digest and size, and its decompressed tar hash matches the ordered DiffID.
5. Reconstructing the three parts produces the original payload SHA-256.

Client debug output is supplementary evidence. Server-side logs and measured
bytes are authoritative because a successful pull alone cannot show which
route supplied cached content.

## Experiment matrix

Run raw `curl` probes first to establish server behavior, followed by `crane`,
`skopeo`, and Docker where available. Reset to a clean client content store
before every materialization and negative case. Use unique synthetic tags only
as an additional safeguard; tags do not replace clearing content-addressed
caches.

### Baseline protocol cases

1. **GET redirect.** Request each layer without automatic redirect following,
   assert `307`, the exact absolute `Location`, no body, and no premature origin
   request. Repeat while following redirects and verify final bytes, size, and
   digest.
2. **HEAD redirect.** Repeat with `HEAD`. Prove from origin logs that the method
   remains `HEAD` and no layer body is transferred. Record clients that do not
   use `HEAD`; absence of a client `HEAD` is not itself a failure.
3. **Range.** Send first-byte, suffix, middle, and unsatisfiable `Range`
   requests. The control plane returns the same `307`; the client must preserve
   `GET` and the `Range` header at the target. Verify `206` slices and the `416`
   response. Also record whether each OCI client uses ranges in ordinary pulls.
4. **Method preservation.** Use `GET`, `HEAD`, and a rejected mutation method
   to demonstrate why `307`, rather than `302` or `303`, is used. Redirected
   `GET` and `HEAD` retain their methods; mutation methods are rejected before
   routing and never reach an origin.
5. **Location handling.** Establish absolute HTTP URLs as the required path.
   Separately test a relative `Location`, a URL containing an escaped path and
   query string, and a missing or malformed `Location`. Record normalization
   and rejection by each client; these variants are compatibility observations,
   not baseline requirements.
6. **Digest verification.** For every followed redirect, hash the final body
   independently before decompression. Then materialize and reconstruct through
   each client from its clean store.
7. **Cross-origin headers.** Send sentinel `Authorization`, `Cookie`, and a
   harmless custom header to the control plane. Because all targets are a
   different origin, assert that credentials are not forwarded. Record which
   non-sensitive headers (`Range`, `User-Agent`, request ID) are forwarded.
   The baseline origins require no authorization; authenticated targets are
   explicitly deferred.

### Failure and integrity cases

Each case must fail closed, produce no successful reconstruction, and retain
both-hop evidence:

- **Redirect loop:** map one layer back to itself and then through a two-node
  loop. Confirm clients stop at a bounded redirect count rather than hanging.
- **Unreachable target:** use a closed local port and separately an origin that
  closes the connection. Confirm a transport failure is reported as a blob
  retrieval failure.
- **Wrong bytes:** serve a body whose size and digest differ, and a same-size
  corrupted body, under the expected digest-shaped URL. Confirm independent
  verification and each OCI client reject the descriptor mismatch. A URL that
  contains the expected digest is never proof of content identity.
- **Target mutation:** complete one successful fetch, replace the target bytes
  without changing the mapping, and retry from a newly clean store. The second
  run must detect the mismatch. Repeat a ranged fetch with mutation between
  requests to expose clients that assemble inconsistent versions; record
  `ETag`/conditional-request behavior.
- **Missing mapping:** request a valid-looking but unmapped digest and confirm
  a control-plane `404` without any origin request.

## Threats to a convincing proof

- A client may bypass the control plane by using an origin URL learned outside
  the manifest flow. The manifest contains only descriptors, not origin URLs;
  require logs showing every layer request reached the control plane before its
  mapped origin.
- Docker, containerd, BuildKit, crane, a proxy, or an origin may satisfy a
  request from a local cache. Begin with isolated empty client stores, disable
  HTTP caches, use `Cache-Control: no-store`, and retain logs proving both hops.
- Origins may serve arbitrary bytes under a URL containing the expected digest.
  Hash actual response bodies and compare sizes; never trust paths, `ETag`, or
  success status as integrity evidence.
- Shared volumes or accidentally reachable files can make the three origins
  appear independent. Give each origin only its assigned blob and assert that
  the other two digest paths return `404`.
- Redirect-following tools may hide intermediate responses, rewrite methods,
  drop `Range`, forward sensitive headers, or normalize `Location`. Preserve
  logs from both servers and test the HTTP behavior directly before relying on
  high-level client output.
- Existing tags or registry state can point at stale metadata. Use immutable
  run-specific inputs and compare fetched manifest and config bytes by digest.
- A successful filesystem extraction can mask descriptor or layer-order
  errors. Preserve all phase-one digest, DiffID, descriptor-order, and final
  reconstruction checks.

## Phase-two exit condition

Local redirect behavior is established when the baseline succeeds from clean
stores with the raw API probe and at least one standards-oriented OCI client,
all failure cases fail closed, and the evidence proves both routing and content
identity. Only then should a follow-up design introduce public registries,
object storage, signed URLs, authentication, or CloudFront.
