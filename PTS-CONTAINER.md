# PTS Container Environment

`pts` is a shell function that runs Polytoken inside a rootless Podman container. It provides a repeatable Fedora-based development environment with project-oriented filesystem isolation. PTS is intended for trusted projects, not hostile code: nested-container support uses privileged execution, host networking, devices, selected credentials, and disabled SELinux labels.

## What the container provides

The shared image is built from `quay.io/fedora/fedora-minimal:latest` and installs:

- Python 3, pip, and pytest
- Git, GitHub CLI (`gh`), `jq`, Go, and ZIP tools
- Node.js and npm
- `yaml-language-server`, exposed as `/usr/local/bin/yamlls` for Polytoken LSP discovery
- Podman and Docker tooling
- Browser/runtime libraries, PDF utilities, networking tools, and process utilities

The image is built automatically on first use and cached as `localhost/polytoken-sandbox:latest`. A project may provide `.polytoken/Containerfile` to build a project-specific image from the shared image.

## Container runtime

PTS launches the image with:

- rootless Podman and `--userns=keep-id`, so files created in the project normally retain the invoking host user's ownership
- SELinux labeling disabled for the bind mounts (`--security-opt label=disable`)
- host networking (`--network=host`), allowing provider API calls without a container-private network
- the current project directory as the working directory
- `HOME` redirected to `<project>/.polytoken`
- `--rm`, so the application container itself is removed after exit; persistent state is stored in bind mounts and project files

The host Polytoken binary is mounted read-only at `/opt/polytoken-seed/polytoken` when present. On the first run, PTS copies it into the shared `polytoken-sandbox-bin` volume and executes `/opt/polytoken-bin/polytoken` from then on. Run `pts update` to update that persistent copy; changing the host binary alone does not replace an existing volume copy.

## Host filesystem access

By default, PTS exposes only these host paths:

| Host path | Container path | Mode | Purpose |
|---|---|---|---|
| Current working directory | Same absolute path | Read/write | Project files and Polytoken state |
| `~/.local/bin/polytoken` | `/opt/polytoken-seed/polytoken` | Read-only, if present | Initial source for the shared Polytoken binary volume |
| `~/.local/share/polytoken/auth/codex/` | `$HOME/.local/share/polytoken/auth/codex/` | Read/write | Shared Polytoken Codex auth and token refresh |
| `~/.bashrc.d/polytoken-sandbox/angel/skills/` | `$HOME/skills/` | Read-only | Angel skills |
| `~/.bashrc.d/polytoken-sandbox/angel/subagents/` | `$HOME/subagents/` | Read-only | Angel subagents |
| `~/.job_digest/secrets.json` | Same absolute path | Read-only, if present | Job-digest credentials/data |

The rest of the host home directory is **not** mounted. In particular, the container does not automatically receive the host's shell configuration, Git configuration, SSH keys, Codex CLI state, caches, or unrelated personal files. The Codex entry above is Polytoken's own auth store, not Codex CLI's separate `~/.codex` directory.

Projects can request additional mounts using `.polytoken/volumes`, but PTS refuses to read that file unless the operator explicitly opts in for the invocation:

```bash
PTS_ALLOW_PROJECT_VOLUMES=1 pts
```

After reviewing the file, it contains one Podman `-v`-style mount specification per line, for example:

```text
/home/will/work/docker_files:/home/will/work/docker_files
```

These mounts are passed through as written after the explicit opt-in. They can expose arbitrary host paths or writable destinations, so do not enable them for untrusted projects.

## Project layout and persistence

On each invocation, PTS creates or updates:

```text
<project>/
└── .polytoken/
    ├── .config/polytoken/
    │   ├── config.yaml          # regenerated from config-template.yaml
    │   ├── AGENTS.md             # copied global instructions
    │   ├── hooks.json            # Polytoken hooks
    │   ├── ponytail-config.json  # Ponytail configuration
    │   └── hooks/
    │       └── ponytail-hook.sh
    ├── .cache/polytoken/         # provider/catalog and application cache
    └── .local/share/polytoken/   # logs, sessions, credentials, and state
```

`<project>/.polytoken` is the container's effective home and persists across runs because it is part of the project-directory bind mount. `config.yaml` is overwritten from the repository template on every `pts` invocation; project changes should be made in the template or launcher rather than directly in the generated file.

The state directory can contain session history, logs, caches, and authentication material. Projects should add `.polytoken/` to `.gitignore` and should not commit it.

## Authentication and credentials

Provider API keys are read from exported variables in the host `~/.bashrc` on every invocation and passed into the container as environment variables. The current launcher forwards keys for OpenAI, Anthropic, Z.ai, NeuralWatt, Brave, Tavily, Exa, and Kagi. Values are not written into the generated configuration; the configuration uses environment-variable interpolation.

GitHub authentication is handled separately:

- PTS obtains a GitHub token using the host `gh auth token` command.
- It passes the token as `GH_TOKEN`.
- It configures Git's GitHub credential helper through `GIT_CONFIG_*` variables.
- The host `~/.gitconfig` is not mounted.

Codex authentication uses Polytoken's global auth store when configured by the launcher:

```text
Host:       ~/.local/share/polytoken/auth/codex/
Container:  $HOME/.local/share/polytoken/auth/codex/
Mode:       read/write
```

This permits one `polytoken auth provider login --provider codex` to serve both host Polytoken and PTS. It does not mount Codex CLI's separate `~/.codex` directory.

## Nested containers and Docker

The PTS image includes Docker and Podman clients plus the privileges and device mappings needed by projects that deliberately run nested containers. The current launcher does **not** start a Docker daemon, set `DOCKER_HOST`, create a Docker socket, or mount the host Docker socket. Docker-dependent workflows must provide and verify their own daemon endpoint; do not assume that `docker info` will succeed merely because the client is installed.

The outer container uses host networking and privileged execution because nested-container workflows may require them. This is part of the trusted-project boundary, not a promise that the outer container isolates hostile code.

## Optional project extensions

A project may customize the environment without changing the shared image:

- `.polytoken/Containerfile` — builds a project-specific image based on the shared image
- `.polytoken/volumes` — explicitly adds host/container mounts
- `config-template.yaml` — controls the generated Polytoken provider and integration configuration
- `ponytail/` — supplies the copied hooks and configuration used by the launcher

These files are read from the host before the container starts. The project-specific Containerfile is built only when its image is absent; rebuild it manually when its dependencies change.

## Security and operational boundaries

PTS is isolation for convenience and reproducibility, not a hostile-code security boundary. The container has host networking, receives selected credentials, may receive user-approved extra mounts, and uses the privileges required by the nested-container setup when that setup is enabled. Treat prompts, project Containerfiles, `.polytoken/volumes`, and agent actions as code with access to every path explicitly mounted into the container.

The default policy is intentionally narrow: mount the current project, the Polytoken executable, selected credential material, and nothing else from the host home directory.
