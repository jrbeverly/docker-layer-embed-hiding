FROM busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f

# Keep the payload addition as the final and only filesystem-producing step.
COPY --chown=0:0 --chmod=0644 archive.part-03 /payload/archive.part3
