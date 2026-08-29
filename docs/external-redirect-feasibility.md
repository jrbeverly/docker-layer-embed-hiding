# External blob redirect feasibility

The local experiment establishes only that unauthenticated clients can follow
absolute HTTP `307` responses to isolated local origins while preserving OCI
descriptor integrity. It is not evidence that external hosting is production
ready. The following areas require separate design and testing before any
public or private upstream is used.

- **Authentication:** determine how the control plane authenticates clients
  without forwarding bearer tokens, cookies, or registry credentials across
  origins. Each target's authorization model and token audience must be tested.
- **Expiring URLs:** define safe lifetimes, clock-skew handling, retry behavior,
  and refresh semantics for signed URLs. A client may resolve a manifest and
  fetch its layers much later or retry a partial transfer after expiry.
- **Range requests:** validate that every target and CDN preserves `Range`,
  `If-Range`, `ETag`, `206`, and `416` semantics. The local origin implements
  these protocol primitives, but interoperability with external clients and
  intermediaries remains unproven.
- **Client allowlists:** record which client and version combinations accept
  cross-origin redirects, plain versus TLS targets, host changes, and any
  registry policy restrictions. Compatibility must be an explicit allowlist,
  not inferred from the local result.
- **Upstream durability:** define availability, retention, garbage-collection,
  immutability, and monitoring requirements. A content digest does not ensure
  that an upstream continues to retain or serve the blob.
- **CDN behavior:** test cache keys, cache-control, redirect caching, range
  coalescing, content encoding, header stripping, origin failover, and stale
  content. CDN responses must still be hashed and sized against the manifest
  descriptor.

TLS, private registries, rate limits, observability, abuse controls, and
multi-region failure behavior also need an explicit threat model and evidence
contract. None of these capabilities is implemented or claimed by the local
experiment.
