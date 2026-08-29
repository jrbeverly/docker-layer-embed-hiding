# Source image 3 fixture

The Dockerfile uses a pinned BusyBox base. Its final and only
filesystem-producing instruction after the base copies `archive.part-03` to
the normalized layer path `payload/archive.part3`.

The build context is prepared by `scripts/publish-source-images.sh`; generated
payload bytes are not stored in this fixture directory.
