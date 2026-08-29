# Source image 2 fixture

The Dockerfile uses a pinned Alpine base. Its final and only
filesystem-producing instruction after the base copies `archive.part-02` to
the normalized layer path `payload/archive.part2`.

The build context is prepared by `scripts/publish-source-images.sh`; generated
payload bytes are not stored in this fixture directory.
