SHELL := /bin/sh

.PHONY: help tools-check payload payload-validate layer layer-validate source-images source-blobs mount-blobs synthetic-manifest publish-synthetic client-matrix reconstruct phase-one proof local-redirects clean-artifacts registry-up registry-down registry-reset registry-status validate

help:
	@printf '%s\n' \
	  'proof            Run the complete phase-one proof from a clean registry (RUN_ID=<id> optional)' \
	  'tools-check      Check required tools and pinned versions' \
	  'payload          Generate the deterministic payload and metadata' \
	  'payload-validate Generate twice and verify identical payloads' \
	  'layer            Generate one controlled payload layer and metadata' \
	  'layer-validate   Compare the controlled layer with two builder outputs' \
	  'source-images    Build, publish, and validate three run-tagged source images' \
	  'source-blobs     Inventory and verify source layer blobs (RUN_ID=<id>)' \
	  'mount-blobs      Probe visibility and mount blobs into synthetic repository (RUN_ID=<id>)' \
	  'synthetic-manifest Generate and validate the synthetic OCI config and manifest (RUN_ID=<id>)' \
	  'publish-synthetic  Publish the synthetic image through the Distribution API (RUN_ID=<id>)' \
	  'client-matrix     Test the synthetic image client compatibility matrix (RUN_ID=<id>)' \
	  'reconstruct       Reconstruct and verify the original payload from layer blobs (RUN_ID=<id>)' \
	  'phase-one         Produce the phase-one auditable gate report (RUN_ID=<id>)' \
	  'local-redirects   Run the phase-two local redirect experiment (RUN_ID=<completed-phase-one-id>)' \
	  'clean-artifacts  Remove all generated artifacts (registry state is not affected)' \
	  'registry-up      Start the pinned local OCI registry' \
	  'registry-down    Stop the local OCI registry' \
	  'registry-reset   Discard registry state and start a clean registry' \
	  'registry-status  Query the local registry API' \
	  'validate         Run repository validation checks'

tools-check:
	@sh scripts/tools-check.sh

payload:
	@sh scripts/generate-payload.sh

payload-validate:
	@sh scripts/validate-payload.sh

layer: payload
	@sh scripts/generate-layer.sh

layer-validate:
	@sh scripts/validate-layer.sh

source-images: registry-up
	@sh scripts/publish-source-images.sh "$(RUN_ID)"

source-blobs: registry-up
	@sh scripts/inventory-source-blobs.sh "$(RUN_ID)"

mount-blobs: registry-up
	@sh scripts/mount-source-blobs.sh "$(RUN_ID)"

synthetic-manifest:
	@sh scripts/generate-synthetic-manifest.sh "$(RUN_ID)"

publish-synthetic: registry-up
	@sh scripts/publish-synthetic-image.sh "$(RUN_ID)"

client-matrix: registry-up
	@sh scripts/test-client-matrix.sh "$(RUN_ID)"

reconstruct:
	@sh scripts/reconstruct-payload.sh "$(RUN_ID)"

phase-one:
	@sh scripts/phase-one-report.sh "$(RUN_ID)"

local-redirects:
	@sh scripts/test-local-redirects.sh "$(RUN_ID)"

proof:
	@sh scripts/run-proof.sh "$(RUN_ID)"

clean-artifacts:
	@rm -rf artifacts/

registry-up: tools-check
	@docker compose up --detach --wait registry

registry-down:
	@docker compose down

registry-reset:
	@docker compose down --volumes --remove-orphans
	@docker compose up --detach --wait registry

registry-status:
	@curl --fail --silent --show-error --dump-header - http://localhost:5000/v2/ --output /dev/null

validate: tools-check
	@docker compose config --quiet
	@sh -n scripts/tools-check.sh scripts/install-crane.sh scripts/generate-payload.sh scripts/validate-payload.sh scripts/generate-layer.sh scripts/validate-layer.sh scripts/publish-source-images.sh scripts/inventory-source-blobs.sh scripts/mount-source-blobs.sh scripts/generate-synthetic-manifest.sh scripts/publish-synthetic-image.sh scripts/test-client-matrix.sh scripts/reconstruct-payload.sh scripts/phase-one-report.sh scripts/run-proof.sh scripts/test-local-redirects.sh
	@python3 -c 'import ast; ast.parse(open("scripts/local-redirect-server.py", encoding="utf-8").read())'
	@sh scripts/validate-payload.sh
	@sh scripts/validate-layer.sh
