#!/usr/bin/env bash
# Build a minimal Ollama Linux/AMD64 image with CPU and CUDA 12.2 runners.

set -euo pipefail

image_tag='ollama:cuda12.2'
ollama_ref='main'
cuda_architectures='61;70;75;80;86;89;90'
no_cache=false
keep_source=false

usage() {
  cat <<'EOF'
Usage: bash ./build-ollama-cuda12-container.sh [options]

Options:
  --image-tag TAG              Output image tag (default: ollama:cuda12.2)
  --ollama-ref REF             Ollama branch or tag (default: main)
  --cuda-architectures LIST    Semicolon-separated CUDA architectures
                               (default: 61;70;75;80;86;89;90)
  --no-cache                   Build without Docker layer cache
  --keep-source                Keep the temporary Ollama checkout
  -h, --help                   Show this help text

The script clones Ollama, applies the bundled CUDA 12.2 Dockerfile patch, and
builds the cuda12-image target. Docker must be running.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)
      require_value "$@"
      image_tag="$2"
      shift 2
      ;;
    --ollama-ref)
      require_value "$@"
      ollama_ref="$2"
      shift 2
      ;;
    --cuda-architectures)
      require_value "$@"
      cuda_architectures="$2"
      shift 2
      ;;
    --no-cache)
      no_cache=true
      shift
      ;;
    --keep-source)
      keep_source=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

for command in docker git mktemp; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || \
  die 'Docker daemon is unavailable. Start Docker and try again.'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
patch_file="$script_dir/ollama-cuda122.patch"
[[ -f "$patch_file" ]] || die "Upstream Dockerfile patch was not found: $patch_file"

source_directory="$(mktemp -d "${TMPDIR:-/tmp}/ollama-cuda122-XXXXXXXX")"

cleanup() {
  if "$keep_source"; then
    printf 'Source checkout retained at %s\n' "$source_directory"
  else
    rm -rf -- "$source_directory"
  fi
}
trap cleanup EXIT

git -c core.autocrlf=false -c core.eol=lf clone --depth 1 --branch "$ollama_ref" \
  https://github.com/ollama/ollama.git "$source_directory" || \
  die "Could not download Ollama ref '$ollama_ref'."

git -C "$source_directory" apply --check --unidiff-zero "$patch_file" || \
  die 'The upstream Dockerfile changed and the CUDA 12.2 patch no longer applies.'
git -C "$source_directory" apply --unidiff-zero "$patch_file" || \
  die 'Could not apply the CUDA 12.2 Dockerfile patch.'

build_args=(
  build
  --pull
  --target cuda12-image
  --tag "$image_tag"
  --build-arg "CUDA_ARCHITECTURES=$cuda_architectures"
)
if "$no_cache"; then
  build_args+=(--no-cache)
fi
build_args+=("$source_directory")

DOCKER_BUILDKIT=1 docker "${build_args[@]}"

printf 'Built %s\n' "$image_tag"
printf 'Run: docker run --rm --gpus all -p 11434:11434 -v ollama:/root/.ollama %s\n' "$image_tag"
