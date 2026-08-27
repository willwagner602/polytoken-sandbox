# PTS Container Environment

`pts` is a shell function that runs Polytoken inside a rootless Podman container. It provides a repeatable Fedora-based development environment with project-oriented filesystem isolation. PTS is intended for trusted projects, not hostile code: nested-container support uses privileged execution, host networking, devices, selected credentials, and disabled SELinux labels.

## Operator commands

Use `pts` to continue the most recent project session, or reconnect to the sole running managed container. Use `pts ps`, `pts attach [ID|name]`, `pts stop [ID|name]`, `pts stats [ID|name]`, `pts diagnose [ID|name]`, and `pts prune`. Targets are resolved only from PTS-owned labels and destructive operations use exact full IDs. `pts continue SESSION_ID` replays durable history; it is distinct from live detach/reattach.

## What the container provides

The shared image is built from `quay.io/fedora/fedora-minimal:latest` and installs:

- Python 3, pip, and pytest
- Git, GitHub CLI (`gh`), `jq`, Go, and ZIP tools
- Node.js and npm
- `yaml-language-server`, exposed as `/usr/local/bin/yamlls` for Polytoken LSP discovery
- OpenAI Codex CLI, installed as the `codex` command
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
- a unique PTS-managed name and ownership/project labels, so every container is attributable without broad process matching
- `--init`, memory `12g`, total memory+swap `16g`, and PID limit `2048` by default; override with `PTS_MEMORY`, `PTS_MEMORY_SWAP`, and `PTS_PIDS_LIMIT`
- managed `create`/`start -ai` lifecycle; abnormal HUP/TERM cleanup uses the recorded full ID, `PTS_STOP_TIMEOUT` (default 10 seconds), then bounded kill escalation
- deliberate `/detach` and Ctrl+D retain the running bounded container; `/quit` removes it after classification. `pts continue SESSION_ID` replays durable history after termination
- `pts ps`, `attach`, `stop`, `stats`, `diagnose`, and confirmed `prune` operate only on PTS-labeled containers
- persistent state is stored in bind mounts and project files; SIGKILL, host crash, and power loss can leave a labeled stopped container for explicit recovery

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
| `~/.codex/` | `$HOME/.codex/` | Read/write | OpenAI Codex CLI ChatGPT/subscription login and CLI state |

The rest of the host home directory is **not** mounted. In particular, the container does not automatically receive the host's shell configuration, Git configuration, SSH keys, caches, or unrelated personal files. The table above has two distinct, deliberate Codex-related exceptions: Polytoken's own Codex provider auth store, and the separate OpenAI Codex CLI's `~/.codex` state.

A project can also request additional mounts via `.polytoken/volumes` or extend the shared image via `.polytoken/Containerfile`. Since these files are project-controlled, PTS gates both behind one-time interactive confirmation before building or mounting either — without this, a cloned (or otherwise untrusted) repo could silently escalate to arbitrary host access the moment `pts` runs inside it:

```text
pts: /path/to/project/.polytoken/volumes will have every line bind-mounted verbatim into this --privileged container
pts: trust and apply this file? [y/N]
```

Confirmation is pinned to a sha256 of the file's content, not just "this project" — editing the file after approval (e.g. a benign version trusted once, then swapped for something malicious) requires re-approval rather than silently inheriting the old decision. The marker is stored in user-owned state under `$XDG_STATE_HOME` (or `~/.local/state`) with mode 600, not in the project tree. Declining, or running with no input available (non-interactively, or a read that times out after 30s), skips the file for that invocation.

After reviewing and approving `.polytoken/volumes`, it contains one Podman `-v`-style mount specification per line. PTS requires absolute paths, requires the source to exist, resolves symlinks before checking, and rejects host-root, system, runtime, and credential paths — including home credential/config stores such as `.ssh`, `.aws`, `.gnupg`, `.config`, `.docker`, `.kube`, `.codex`, `.netrc`, and Polytoken's own host state; for example:

```text
/home/will/work/docker_files:/home/will/work/docker_files
```

These mounts are passed through once approved after the path checks above. Writable mounts can still expose project-trusted host paths, so only approve files from projects you trust.

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

- PTS prefers an exported `GH_TOKEN`, then `GITHUB_TOKEN`, and otherwise obtains a token using the host `gh auth token` command.
- It passes the selected token into the container as `GH_TOKEN`.
- It configures Git's GitHub credential helper through `GIT_CONFIG_*` variables.
- The host `~/.gitconfig` is not mounted.

Codex authentication uses Polytoken's global auth store when configured by the launcher:

```text
Host:       ~/.local/share/polytoken/auth/codex/
Container:  $HOME/.local/share/polytoken/auth/codex/
Mode:       read/write
```

This permits one `polytoken auth provider login --provider codex` to serve both host Polytoken and PTS. The OpenAI Codex CLI is a separate tool. Its `~/.codex/` state is not mounted by default; set `PTS_SHARE_CODEX=1` explicitly when reusing Codex login state inside PTS is required. The two auth stores must not be conflated.

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

## Diagnostics and incident response

`pts diagnose` and abnormal cleanup write private, bounded bundles below
`.polytoken/pts/diagnostics/<project-hash>/`. Bundles contain operational identity,
state, exit/OOM indicators, effective limits, and bounded stats output when
available. They do not contain container environments, credentials, credential
files, prompts, complete session JSONL, command arguments, or unbounded logs.
Diagnostics are best effort and never replace exact-ID cleanup. SIGKILL, host
crash, and power loss can prevent capture and leave a stopped labeled container
for later `pts ps`, `pts diagnose`, `pts stop`, or confirmed `pts prune` recovery.

If bounded growth recurs, preserve the diagnostic bundle and identify the
container/session/time window first. Reproduce with a known workload under the
configured limit, then collect upstream-supported heap/allocation profiling and
Polytoken metrics/logs in the Polytoken source environment. Compare session
history size, task/subagent fan-out, caches, and heap growth as hypotheses—not
conclusions—and do not copy credentials or full prompt/session contents into
shared artifacts. Open a separate upstream fix only when measured retained
allocations identify a cause.

## Security and operational boundaries

PTS is isolation for convenience and reproducibility, not a hostile-code security boundary. The container has host networking, receives selected credentials, may receive user-approved extra mounts, and uses the privileges required by the nested-container setup when that setup is enabled. Treat prompts, project Containerfiles, `.polytoken/volumes`, and agent actions as code with access to every path explicitly mounted into the container.

The default policy is intentionally narrow: mount the current project, the Polytoken executable, selected credential material, and nothing else from the host home directory.
