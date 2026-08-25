# polytoken-repo: purpose and context

## Purpose

This repository defines the local `pts` wrapper used to run Polytoken inside a rootless Podman sandbox. Its primary goals are:

- isolate the Polytoken process from the host filesystem and home directory;
- provide a repeatable Fedora-based tool environment;
- keep Polytoken state scoped to the project being worked on;
- pass provider credentials without copying literal secrets into project configuration; and
- support workflows that need a nested Docker daemon, Chromium/Playwright libraries, or PDF utilities.

This is infrastructure around Polytoken, not the Polytoken application source. The Polytoken executable is supplied by the host and mounted read-only into the sandbox.

## Repository contents

- `polytoken-sandbox.sh` — defines the `pts` shell function. It builds/selects the image, prepares project state, mounts approved paths, starts the nested Docker daemon, and launches Polytoken.
- `Containerfile` — defines the shared Fedora sandbox image. It installs the command-line, development, container, Chromium/Playwright, and PDF runtime dependencies.
- `config-template.yaml` — secret-free Polytoken configuration copied into each project state directory on every launch.
- `AGENTS.md` — instructions copied into the effective Polytoken configuration so future agents understand repository conventions and the sandbox Docker environment.
- `ponytail/` — Ponytail instructions, skills, hooks, and configuration propagated into each project’s Polytoken state.
- `README.md` — setup and user-facing usage documentation.

## Launch flow

Running `pts` from a project directory follows this shape:

1. Confirm rootless Podman is available.
2. Build `localhost/polytoken-sandbox:latest` when absent or when the `Containerfile` hash changes.
3. If the project has `.polytoken/Containerfile`, build/use its project-specific image instead.
4. Copy the template configuration, agent instructions, Ponytail hook, and Ponytail configuration into the project’s `.polytoken/` directory.
5. Mount the current project directory read/write.
6. Mount `~/.local/bin/polytoken` read-only as `/usr/local/bin/polytoken`.
7. Mount the explicitly approved host directory `/home/will/work/docker_files` at the same path, read/write, via `.polytoken/volumes`.
8. Optionally mount `~/.job_digest/secrets.json` read-only and any other explicit mounts listed in `.polytoken/volumes`.
9. Refresh provider credentials from the host shell configuration and pass them as environment variables.
10. Start a Docker daemon as the privileged sandbox root, wait for `docker info`, and then run Polytoken as the project user.

The container uses host networking so model APIs and nested container workloads can reach the network. The outer Podman invocation uses `--privileged`, `--userns=keep-id`, SELinux label disabling, and host networking because the nested Docker daemon setup requires those capabilities in this environment.

## Filesystem and state model

Only the invocation directory and explicitly selected files are exposed to the container; the host home directory is not generally mounted. The approved `/home/will/work/docker_files` directory is an intentional read/write exception and is visible at the same path inside the sandbox. The container’s `HOME` is the project’s `.polytoken` directory, so Polytoken configuration, cache, authentication, and session data persist per project.

The project state directory may contain sensitive session history and device-auth material. Projects should add `.polytoken/` to `.gitignore`. The generated `config.yaml` contains provider references such as `${OPENAI_API_KEY}`, not literal API keys, and is overwritten from the template on each `pts` invocation.

## Nested Docker

The launcher starts `dockerd` as the privileged sandbox root inside the sandbox. It sets:

```text
XDG_RUNTIME_DIR=/tmp/run-0
DOCKER_HOST=unix:///tmp/run-0/docker.sock
```

The daemon uses `vfs` storage and disables iptables and Docker bridge networking because the host kernel does not provide the required NAT modules. Docker-dependent agents should:

```bash
docker info
docker run --network=host ...
```

Do not start a second daemon or assume the host Docker socket is available. If startup fails, inspect `/tmp/dockerd.log`. The launcher currently continues into Polytoken after a Docker timeout, so Docker-dependent work must verify readiness explicitly.

## Browser and PDF support

The base image includes Fedora packages needed by Chromium/Playwright, including `nss`, `nspr`, GTK/X11 libraries, audio support, graphics/GBM support, and related runtime libraries. It also includes `poppler-utils`, which provides:

- `pdftotext`
- `pdfinfo`

The repository does not install a project’s Playwright package or browser bundle. A workflow that owns Playwright remains responsible for installing its browser, for example with its normal `npx playwright install chromium` command. The image supplies the system libraries so that installation and execution do not require host administrator privileges.

## Extension points and constraints

A project can commit `.polytoken/Containerfile` to extend the shared image with project-specific packages. It can also commit `.polytoken/volumes` for deliberate additional `-v` mounts, one mount specification per line.

Keep changes minimal and image-level when a dependency is shared by all sandboxed projects. Do not add application substitutes for canonical workflows without verification. When changing `Containerfile`, the launcher’s content hash causes the shared image to rebuild automatically on the next `pts` invocation.

## Security boundary

The sandbox is isolation by filesystem exposure, not a hostile multi-tenant security boundary. The outer container is intentionally privileged to enable nested rootless container operations. Credentials are passed to the container for the duration of the run, while the host’s general home directory and host Docker socket remain unmounted.

## Troubleshooting record: Docker and agent context

This record documents the investigation performed while making the sandbox usable for Docker-dependent agents.

### Initial symptoms

- The launcher copied `AGENTS.md` from a `$HOME`-derived path. In this environment, the repository was available at `/home/will/.bashrc.d/polytoken-sandbox`, while the shell environment also exposed `/var/home/will` paths. The source lookup therefore failed in some invocations.
- Project state did not receive `AGENTS.md` when an image build failed, because synchronization happened after image building.
- Image builds failed at Fedora package installation with `Could not resolve host: mirrors.fedoraproject.org`.
- Nested `dockerd-rootless.sh` failed with `newuidmap ... Operation not permitted` when started inside the privileged outer container. `--userns=keep-id:size=65536` did not solve that nested UID-map failure.
- Agents sometimes attempted `sudo`, `systemctl start docker`, or `service docker`. Those commands are wrong here: the sandbox does not run systemd as PID 1, does not provide a host Docker service, and does not mount the host Docker socket.
- Some Docker-aware tooling selected the project-local path `.polytoken/.docker/run/docker.sock` instead of the launcher’s daemon socket.

### Changes that resolved the issues

`polytoken-sandbox.sh` now:

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
