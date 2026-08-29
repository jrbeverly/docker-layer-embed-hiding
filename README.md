# Synthetic OCI Archive From Distributed Layers

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Recomposes payload layers from independent images into a new OCI image without rebuilding the layer bytes.

The experiment also tests whether OCI clients can retrieve those layers through redirects to isolated HTTP origins.

```sh
sh scripts/install-crane.sh
make validate
make proof RUN_ID=my-run
make local-redirects RUN_ID=my-run
```

Generated evidence is written beneath `artifacts/`. See [VISION.md](VISION.md) and the [experiment contract](docs/oci-experiment-contract.md) for the complete hypotheses and evidence gates.

## Notes

- idea; OCI manifest as a pointer to arbitrary layers
- question; can layers from multiple different images be referenced/composed together
- embed data/resources across separate OCI images/layers
- final image then pulls those existing layers and stacks them together
- effectively treat an OCI image as a link map to resources stored across multiple locations/images
- interesting direction for distributed composition without repackaging everything into one artifact
