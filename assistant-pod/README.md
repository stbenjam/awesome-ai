# assistant-pod

Yes, there are a billion "run AI coding tools in a container" projects. None of them
quite did what I wanted: a single image with all the tools I actually use, my existing
configs bind-mounted in, and nothing else. No orchestration layer, no daemon, no
opinions about how I should work. Just a container I can YOLO in more safely.

## What's in the box

| Tool | What it is |
|------|-----------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Anthropic's CLI agent |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Google's CLI agent |
| [Codex](https://github.com/openai/codex) | OpenAI's CLI agent |
| [opencode](https://github.com/opencode-ai/opencode) | Terminal-native AI assistant |

The image also includes [Aikido safe-chain](https://github.com/AikidoSec/safe-chain)
to guard against supply-chain attacks during the npm install phase of the build.

## Quick start

```bash
git clone https://github.com/stbenjam/awesome-ai.git
cd awesome-ai/assistant-pod
./install.sh
```

By default this pulls the pre-built image from `ghcr.io/stbenjam/assistant-pod:latest`
and adds shell functions to `~/.zshrc` that shadow the native commands. After
restarting your shell (or `source ~/.zshrc`):

```bash
claude          # runs Claude Code in a container
gemini          # runs Gemini CLI in a container
codex           # runs Codex in a container
opencode        # runs opencode in a container
```

All arguments are passed through, so `claude --help`, `gemini chat`, etc. work as
expected.

### Options

```bash
./install.sh --build      # build the image locally instead of pulling from GHCR
./install.sh --bash       # write aliases to ~/.bashrc instead
./install.sh --docker     # use docker instead of podman
```

You can also set `CONTAINER_RT=docker` in your environment.

## How it works

Each command runs `podman run -it --rm` with:

- **`$PWD` → `/workspace`** — your current directory, read-write
- **`~/.claude` → `/home/user/.claude`** — Claude config and auth (respects `CLAUDE_CONFIG_DIR`)
- **`~/.gemini` → `/home/user/.gemini`** — Gemini config and auth
- **`~/.codex` → `/home/user/.codex`** — Codex config and auth
- **`~/.config/opencode` → `/home/user/.config/opencode`** — opencode config

The container runs as a non-root user with `--userns=keep-id`, so files written to
bind mounts keep your host UID.

## Vertex AI / Google Cloud

If you set `GOOGLE_GENAI_USE_VERTEXAI=true` or `CLAUDE_CODE_USE_VERTEX=1` in your
host environment, the wrapper functions will:

1. Mount your full gcloud config (`~/.config/gcloud`, read-only) — Claude Code
   needs `gcloud` available for its auth flow, not just the ADC credentials file
2. Pass through these environment variables (when set):
   - `CLAUDE_CODE_USE_VERTEX`, `CLOUD_ML_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`
   - `GOOGLE_GENAI_USE_VERTEXAI`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`

When neither variable is set, no Google credentials are mounted and the tools use
their own API key logins from their respective config directories.

## Uninstall

Remove the block between `# --- assistant-pod aliases ---` and
`# --- end assistant-pod aliases ---` from your shell config, then:

```bash
podman rmi assistant-pod
```
