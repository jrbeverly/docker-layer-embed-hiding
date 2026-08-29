# Source image 1 fixture

The Dockerfile builds the first source image from the empty `scratch` base. Its
final and only filesystem-producing instruction copies `archive.part-01` to
the normalized layer path `payload/archive.part1`.

The build context is prepared by `scripts/validate-layer.sh` or
`scripts/publish-source-images.sh`; generated payload bytes are not stored in
this fixture directory.
