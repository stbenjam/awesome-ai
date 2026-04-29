#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="assistant-pod"
GHCR_IMAGE="ghcr.io/stbenjam/assistant-pod:latest"
CONTAINER_RT="${CONTAINER_RT:-podman}"
SHELL_RC="${HOME}/.zshrc"
BUILD_LOCAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bash) SHELL_RC="${HOME}/.bashrc"; shift ;;
    --docker) CONTAINER_RT="docker"; shift ;;
    --build) BUILD_LOCAL=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${BUILD_LOCAL}" == "true" ]]; then
  echo "Building ${IMAGE_NAME} locally with ${CONTAINER_RT}..."
  "${CONTAINER_RT}" build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
else
  echo "Pulling ${GHCR_IMAGE}..."
  "${CONTAINER_RT}" pull "${GHCR_IMAGE}"
  "${CONTAINER_RT}" tag "${GHCR_IMAGE}" "${IMAGE_NAME}"
fi

MARKER="# --- assistant-pod aliases ---"

if grep -qF "${MARKER}" "${SHELL_RC}" 2>/dev/null; then
  echo "Aliases already present in ${SHELL_RC}, skipping."
else
  echo "Adding aliases to ${SHELL_RC}..."
  cat >> "${SHELL_RC}" << 'ALIASES'

# --- assistant-pod aliases ---
_assistant_pod_run() {
  local tool="$1"; shift
  local -a args=(
    run -it --rm
    --userns=keep-id
    -v "$PWD:/workspace:rw"
    -w /workspace
  )

  # Claude config dir
  local claude_host_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  args+=(-v "${claude_host_dir}:/home/user/.claude:rw")
  args+=(-e "CLAUDE_CONFIG_DIR=/home/user/.claude")

  # Gemini config
  [[ -d "$HOME/.gemini" ]] && args+=(-v "$HOME/.gemini:/home/user/.gemini:rw")

  # Codex config
  [[ -d "$HOME/.codex" ]] && args+=(-v "$HOME/.codex:/home/user/.codex:rw")

  # opencode config
  [[ -d "$HOME/.config/opencode" ]] && args+=(-v "$HOME/.config/opencode:/home/user/.config/opencode:rw")

  # GitHub CLI config
  [[ -d "$HOME/.config/gh" ]] && args+=(-v "$HOME/.config/gh:/home/user/.config/gh:rw")

  # Git identity
  [[ -f "$HOME/.gitconfig" ]] && args+=(-v "$HOME/.gitconfig:/home/user/.gitconfig:ro")

  # Vertex AI / Google Cloud — mount gcloud config and pass env vars when opted in
  if [[ "${GOOGLE_GENAI_USE_VERTEXAI:-}" == "true" || -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]; then
    if [[ -d "$HOME/.config/gcloud" ]]; then
      args+=(-v "$HOME/.config/gcloud:/home/user/.config/gcloud:ro")
    fi
    [[ -n "${GOOGLE_GENAI_USE_VERTEXAI:-}" ]]      && args+=(-e "GOOGLE_GENAI_USE_VERTEXAI=${GOOGLE_GENAI_USE_VERTEXAI}")
    [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]]          && args+=(-e "CLAUDE_CODE_USE_VERTEX=${CLAUDE_CODE_USE_VERTEX}")
    [[ -n "${CLOUD_ML_REGION:-}" ]]                 && args+=(-e "CLOUD_ML_REGION=${CLOUD_ML_REGION}")
    [[ -n "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]]     && args+=(-e "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID}")
    [[ -n "${GOOGLE_CLOUD_PROJECT:-}" ]]            && args+=(-e "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}")
    [[ -n "${GOOGLE_CLOUD_LOCATION:-}" ]]           && args+=(-e "GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION}")
  fi

  "${CONTAINER_RT:-podman}" "${args[@]}" assistant-pod "$tool" "$@"
}

claude()   { _assistant_pod_run claude "$@"; }
gemini()   { _assistant_pod_run gemini "$@"; }
codex()    { _assistant_pod_run codex "$@"; }
opencode() { _assistant_pod_run opencode "$@"; }
# --- end assistant-pod aliases ---
ALIASES
fi

echo "Done. Restart your shell or run: source ${SHELL_RC}"
