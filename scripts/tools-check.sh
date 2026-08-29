#!/bin/sh

set -u

required_crane_version="0.21.7"
failed=0

pass() {
  printf 'ok: %s\n' "$1"
}

fail() {
  printf 'error: %s\n' "$1" >&2
  failed=1
}

check_command() {
  tool=$1
  hint=$2
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool found at $(command -v "$tool")"
  else
    fail "$tool is required; $hint"
  fi
}

check_command docker "install Docker Engine 24 or newer"
check_command curl "install curl with your system package manager"
check_command jq "install jq with your system package manager"
check_command awk "install a POSIX awk implementation"
check_command tar "install a POSIX tar implementation"
check_command gzip "install gzip with your system package manager"
check_command split "install GNU coreutils"
check_command sha256sum "install GNU coreutils"
check_command python3 "install Python 3 for the local redirect experiment"
check_command crane "run scripts/install-crane.sh or install crane ${required_crane_version}"

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable"
  else
    fail "Docker is installed but its daemon is not reachable; start Docker or use the devcontainer Docker-in-Docker feature"
  fi

  docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
  docker_major=${docker_version%%.*}
  case "$docker_major" in
    ''|*[!0-9]*)
      fail "could not determine the Docker client version"
      ;;
    *)
      if [ "$docker_major" -ge 24 ]; then
        pass "Docker client ${docker_version} satisfies the 24+ baseline"
      else
        fail "Docker Engine 24 or newer is required (found client ${docker_version})"
      fi
      ;;
  esac

  if docker compose version >/dev/null 2>&1; then
    pass "Docker Compose found: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    fail "Docker Compose v2 is required; install the docker-compose-plugin"
  fi

  if docker buildx version >/dev/null 2>&1; then
    pass "Docker Buildx found: $(docker buildx version | awk '{print $2}')"
  else
    fail "Docker Buildx is required for BuildKit builds; install the docker-buildx-plugin"
  fi
fi

if command -v crane >/dev/null 2>&1; then
  crane_version=$(crane version 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9][^[:space:]]*\).*$/\1/p')
  if [ "$crane_version" = "$required_crane_version" ]; then
    pass "crane version is pinned ${required_crane_version}"
  else
    fail "crane ${required_crane_version} is required (found: ${crane_version:-unknown}); run scripts/install-crane.sh"
  fi
fi

if [ "$failed" -ne 0 ]; then
  printf '\nTool check failed. See docs/implementation-plan.md for prerequisites.\n' >&2
  exit 1
fi

printf '\nAll required tools are available.\n'
