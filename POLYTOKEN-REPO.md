# polytoken-repo: purpose and context

## Purpose

This repository defines the local `pts` wrapper used to run Polytoken inside a rootless Podman container. Its primary goals are:

- provide project-oriented filesystem isolation for trusted projects (not a hostile-code security boundary);
- provide a repeatable Fedora-based tool environment;
- keep Polytoken state scoped to the project being worked on;
- pass provider credentials without copying literal secrets into project configuration; and
- support workflows that need a nested Docker daemon, Chromium/Playwright libraries, or PDF utilities.

This is infrastructure around Polytoken, not the Polytoken application source. The host executable is mounted read-only as an optional seed at `/opt/polytoken-seed/polytoken`, copied into the shared `polytoken-sandbox-bin` volume on first use, and then executed from `/opt/polytoken-bin/polytoken`. Run `pts update` to update the persistent copy.

## Repository contents

- `polytoken-sandbox.sh` — defines the `pts` shell function. It builds/selects the image, prepares project state, mounts approved paths, and launches Polytoken with the nested-container runtime prerequisites.
- `Containerfile` — defines the shared Fedora sandbox image. It installs the command-line, development, container, Chromium/Playwright, and PDF runtime dependencies.
- `config-template.yaml` — secret-free Polytoken configuration copied into each project state directory on every launch.
- `AGENTS.md` — instructions copied into the effective Polytoken configuration so future agents understand repository conventions and the sandbox Docker environment.
- `ponytail/` — Ponytail instructions, skills, hooks, and configuration propagated into each project’s Polytoken state.
- `README.md` — setup and user-facing usage documentation.
- `PTS-CONTAINER.md` — complete image package inventory, runtime mounts, persistence, authentication, and nested-container boundaries.

## Launch flow

Running bare `pts` from a project directory defaults to `polytoken continue` (without a session ID), which opens Polytoken's most-recent-session picker; if exactly one live managed container exists, PTS reconnects to it instead. Explicit arguments such as `pts continue SESSION_ID` remain passthrough commands. Running `pts` from a project directory follows this shape. Application containers use default limits of 12 GiB memory, 16 GiB total memory+swap, and 2048 PIDs; `PTS_MEMORY`, `PTS_MEMORY_SWAP`, `PTS_PIDS_LIMIT`, and `PTS_STOP_TIMEOUT` override the documented boundaries. Operators can use `pts ps`, `pts attach`, `pts stop`, `pts stats`, `pts diagnose`, and `pts prune`; intentional detach retains a bounded container while quit/abnormal termination cleans it up and `pts continue SESSION_ID` replays durable history. When the installed Polytoken binary is unavailable, provider-free live-session and durable-continue integration proofs are blocked rather than inferred.


1. Confirm rootless Podman is available.
2. Build `localhost/polytoken-sandbox:latest` when absent or when the `Containerfile` hash changes.
3. If the project has `.polytoken/Containerfile`, build/use its project-specific image instead.
4. Copy the template configuration, agent instructions, Ponytail hook, and Ponytail configuration into the project’s `.polytoken/` directory.
5. Mount the current project directory read/write.
6. Mount the shared `polytoken-sandbox-bin` volume at `/opt/polytoken-bin`; optionally mount `~/.local/bin/polytoken` read-only as `/opt/polytoken-seed/polytoken` for first-run seeding.
7. Mount Polytoken's global Codex provider auth directory read/write, the host `~/.codex/` directory read/write for the OpenAI Codex CLI (separate from Polytoken's own Codex provider auth store), and the Angel skills/subagents read-only.
8. Optionally mount `~/.job_digest/secrets.json` read-only. A project-local `.polytoken/Containerfile` or `.polytoken/volumes` each require one-time interactive confirmation — pinned to a sha256 of that file's content, so editing it after approval re-prompts — before being built or mounted; declined or unconfirmed files are skipped for that run.
9. Refresh provider credentials from the host shell configuration and pass them as environment variables.
10. Launch Polytoken through the image's nested-container-capable runtime, opportunistically starting Codex's device-code login first if it isn't already authenticated. The current launcher does not start a Docker daemon or set `DOCKER_HOST`; Docker-dependent workflows must provide and verify their own daemon endpoint.

The container uses host networking so model APIs and deliberately nested container workloads can reach the network. The outer Podman invocation uses `--privileged`, `--userns=keep-id`, SELinux label disabling, FUSE/TUN devices, and host networking. These are trusted-workflow prerequisites for nested-container tooling, not a hostile-code security boundary.

## Filesystem and state model

Only the invocation directory and explicitly selected files are exposed to the container; the host home directory is not generally mounted. The container’s `HOME` is the project’s `.polytoken` directory, so Polytoken configuration, cache, authentication, and session data persist per project. Additional paths such as `/home/will/work/docker_files` are available only when explicitly listed in `.polytoken/volumes`, and only after the operator interactively confirms that file (confirmation is pinned to a sha256 of its content, so a later edit requires re-approval rather than silently inheriting the old decision).

The project state directory may contain sensitive session history and device-auth material. Projects should add `.polytoken/` to `.gitignore`. The generated `config.yaml` contains provider references such as `${OPENAI_API_KEY}`, not literal API keys, and is overwritten from the template on each `pts` invocation.

## Nested Docker

The image includes Docker and Podman clients plus the runtime prerequisites for deliberately nested container workflows. The current launcher does not start `dockerd`, set `DOCKER_HOST`, create a Docker socket, or mount the host Docker socket. Docker-dependent workflows must provide and verify their own daemon endpoint.

Do not use `sudo`, `systemctl`, or `service` to look for a host daemon from inside PTS: the container does not run systemd and does not expose the host socket. The outer container remains privileged and host-networked because those are retained prerequisites for trusted nested-container workflows, not because PTS is a hostile-code boundary.

## Browser and PDF support

The base image includes Fedora packages needed by Chromium/Playwright, including `nss`, `nspr`, GTK/X11 libraries, audio support, graphics/GBM support, and related runtime libraries. It also includes `poppler-utils`, which provides:

- `pdftotext`
- `pdfinfo`

The repository does not install a project’s Playwright package or browser bundle. A workflow that owns Playwright remains responsible for installing its browser, for example with its normal `npx playwright install chromium` command. The image supplies the system libraries so that installation and execution do not require host administrator privileges.

## Extension points and constraints

A project can commit `.polytoken/Containerfile` to extend the shared image with project-specific packages. It can also commit `.polytoken/volumes` for deliberate additional `-v` mounts, one mount specification per line. Both are gated behind one-time interactive confirmation, pinned to a sha256 of the file's content: PTS prompts before building or mounting either for the first time, and again whenever the file's content changes — a plain "trusted this project" flag would miss a benign version being approved once and then swapped for something malicious later. Declining, or running non-interactively with no input available, skips the file for that invocation rather than failing or auto-approving.

Keep changes minimal and image-level when a dependency is shared by all sandboxed projects. Do not add application substitutes for canonical workflows without verification. When changing `Containerfile`, the launcher’s content hash causes the shared image to rebuild automatically on the next `pts` invocation.

## Security boundary

The sandbox is isolation by filesystem exposure, not a hostile multi-tenant security boundary. The outer container is intentionally privileged to enable nested rootless container operations. Credentials are passed to the container for the duration of the run, while the host’s general home directory and host Docker socket remain unmounted.

## Current Docker limitation

The image includes Docker and Podman clients plus the runtime prerequisites for deliberately nested container workflows, but the current launcher does not start a Docker daemon, set `DOCKER_HOST`, create a Docker socket, or mount the host Docker socket. A project that needs Docker must provide and verify its own daemon endpoint. Do not use `sudo`, `systemctl`, or `service` to look for a host daemon from inside PTS; the container does not run systemd and does not expose the host socket.

The outer container remains privileged, host-networked, and device-enabled because those are retained runtime prerequisites for trusted nested-container workflows. They are not a hostile-code isolation guarantee.

### Historical troubleshooting notes

The notes below record earlier development investigations. They are not the current runtime contract; see **Current Docker limitation** above and the launch flow for current behavior.

- The launcher copied `AGENTS.md` from a `$HOME`-derived path. In this environment, the repository was available at `/home/will/.bashrc.d/polytoken-sandbox`, while the shell environment also exposed `/var/home/will` paths. The source lookup therefore failed in some invocations.
- Project state did not receive `AGENTS.md` when an image build failed, because synchronization happened after image building.
- Image builds failed at Fedora package installation with `Could not resolve host: mirrors.fedoraproject.org`.
- Nested `dockerd-rootless.sh` failed with `newuidmap ... Operation not permitted` when started inside the privileged outer container. `--userns=keep-id:size=65536` did not solve that nested UID-map failure.
- Agents sometimes attempted `sudo`, `systemctl start docker`, or `service docker`. Those commands are wrong here: the sandbox does not run systemd as PID 1, does not provide a host Docker service, and does not mount the host Docker socket.
- Some Docker-aware tooling selected the project-local path `.polytoken/.docker/run/docker.sock` instead of the launcher’s daemon socket.

### Historical implementation notes

The detailed Docker investigation and one-time verification are retained in earlier commits. They established the rootless image-build and nested-container constraints that explain the current privileged runtime, but they are not a description of a currently launched Docker daemon.

The historical implementation notes below are preserved for context:


1. Resolves bundled files relative to the launcher directory rather than assuming `$HOME/.bashrc.d/polytoken-sandbox`.
2. Synchronizes `config.yaml`, `AGENTS.md`, and Ponytail files before image work, so agent context is available even when a rebuild fails.
3. Discovers a usable resolver from a privileged Fedora container and uses it with the rootless-compatible Buildah settings:

   ```text
   --isolation=oci --security-opt=label=disable --dns=<discovered resolver>
   ```

4. Starts `dockerd` as UID 0 inside the already-privileged sandbox container instead of starting another rootless daemon. It uses:

   ```text
   --storage-driver=vfs --iptables=false --bridge=none
   ```

5. Exports a clean Docker CLI environment to the agent:

   ```text
   DOCKER_HOST=unix:///tmp/run-0/docker.sock
   DOCKER_CONFIG=/tmp/docker-cli-config
   DOCKER_CONTEXT=
   ```

6. Changes the daemon socket to group-readable/writable mode and drops Polytoken to the invoking user’s UID/GID with `setpriv`.
7. Creates the compatibility symlink:

   ```text
   <project>/.polytoken/.docker/run/docker.sock -> /tmp/run-0/docker.sock
   ```

### Verification performed

- `bash -n polytoken-sandbox.sh` passed after the launcher changes.
- The full Fedora image rebuild completed successfully, including all package-install steps.
- A privileged container test reached Docker server version `29.7.2` with the `vfs` storage driver.
- The demoted agent-user test succeeded:

  ```text
  agent_uid=1000 agent_gid=1000
  server=29.7.2 driver=vfs
  ```

- A test with an intentionally bad project-local Docker context still succeeded after the clean environment was applied:

  ```text
  uid=1000 host=unix:///tmp/run-0/docker.sock
  server=29.7.2 driver=vfs
  ```

- Both the canonical socket and the compatibility alias resolved to the same daemon:

  ```text
  info=server=29.7.2 driver=vfs
  alias=server=29.7.2 driver=vfs
  ```

- A real `pts` invocation created the compatibility symlink and reached the container-launch stage.

### Remaining limitation

The final `pts` invocation in this development environment could not execute Polytoken because the host-provided binary was absent:

```text
/home/will/.local/bin/polytoken
```

That prevented a complete end-to-end test of the actual Polytoken process. The Docker daemon, `DOCKER_HOST` handoff, agent-user permissions, image build, and project-local socket compatibility were tested independently and passed. A host installation of the Polytoken executable is still required before `pts` can launch the agent.
