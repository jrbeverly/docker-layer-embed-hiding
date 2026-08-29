FROM alpine@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e

# Keep the payload addition as the final and only filesystem-producing step.
COPY --chown=0:0 --chmod=0644 archive.part-02 /payload/archive.part2
