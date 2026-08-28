# polytoken-sandbox

Runs [polytoken](https://github.com) inside a rootless Podman container for
project-oriented filesystem isolation. PTS is intended for trusted projects,
not hostile code: nested-container support uses privileged execution, host
networking, devices, selected credentials, and disabled SELinux labels. Only
the invocation directory and explicitly approved additional mounts are exposed
from the host filesystem; the rest of `$HOME` is not mounted by default.

A repository's `.polytoken/volumes` (and `.polytoken/Containerfile`) is ignored
until the operator interactively confirms it — approval is pinned to a sha256
of the file's content in user-owned state, so a repository cannot pre-seed the
approval and editing it afterward requires re-approval. Extra mounts must use
absolute paths and pass PTS's sensitive-path checks; only approve files from
projects you trust. Host `~/.codex` state is not mounted unless
`PTS_SHARE_CODEX=1` is explicitly set.

## Contents

- `polytoken-sandbox.sh` — the `pts` shell function (copy of the version
  sourced from `~/.bashrc.d/` — see setup below)
- `Containerfile` — builds `localhost/polytoken-sandbox:latest`; the complete
  installed-package and runtime inventory is documented in `PTS-CONTAINER.md`
  and the copied `AGENTS.md`
- `config-template.yaml` — secret-free polytoken config seeded into every
  new project's `.polytoken/` state dir on first run. Provider keys use
  env-var interpolation (`${OPENAI_API_KEY}`, etc.) — no literal secrets.

## Prerequisites

- **podman**, installed and configured for rootless use
- **polytoken** binary at `~/.local/bin/polytoken`
- Fedora-based host with SELinux (Bazzite/Fedora tested)

## Setup on a new machine

1. Clone this repo to `~/.bashrc.d/polytoken-sandbox/`:

   ```bash
   git clone https://github.com/willwagner602/polytoken-sandbox ~/.bashrc.d/polytoken-sandbox
   ```

2. Copy the shell function up one level so `~/.bashrc`'s
   `for rc in ~/.bashrc.d/*` loop sources it automatically (anything that
   isn't a shell script has to live in the subdirectory, or it gets
   misinterpreted as one):

   ```bash
   cp ~/.bashrc.d/polytoken-sandbox/polytoken-sandbox.sh ~/.bashrc.d/polytoken-sandbox.sh
   source ~/.bashrc.d/polytoken-sandbox.sh
   ```

3. Make sure `~/.local/bin/polytoken` exists. PTS seeds the shared
   `polytoken-sandbox-bin` volume from this binary on first use; later runs use
   the volume's persistent copy. Run `pts update` to update that copy (no image
   rebuild is needed).

4. Run `pts` from any project directory. The image builds automatically on
   first run and is cached thereafter. Rebuild manually after editing the
   Containerfile with:

   ```bash
   podman build -t localhost/polytoken-sandbox:latest ~/.bashrc.d/polytoken-sandbox
   ```

## Usage

```bash
pts                    # continue the most recent project session, or reconnect live
pts ps                 # list all managed containers
pts attach [ID|name]   # reattach to the original running managed session
pts stop [ID|name]     # stop one exact managed container
pts stats [ID|name]    # show one-shot resource usage
pts diagnose [ID|name] # capture bounded operational diagnostics
pts prune              # confirm removal of stopped managed containers
pts -- <args>          # pass an otherwise-colliding command to polytoken
```

Application containers are bounded by default to 12 GiB memory, 16 GiB total
memory+swap, and 2048 PIDs. Override these with `PTS_MEMORY`,
`PTS_MEMORY_SWAP`, and `PTS_PIDS_LIMIT`; `PTS_STOP_TIMEOUT` controls the
10-second default graceful-stop window. Podman validates native limit syntax and
platform support. `/detach` or Ctrl+D intentionally leaves the bounded container
running; `/quit` and abnormal wrapper termination clean it up. After cleanup,
`pts continue SESSION_ID` replays durable project history.

Polytoken's own config/cache/auth/session state lives per-project, under
`<project-dir>/.polytoken/`, seeded from `config-template.yaml` on first
run. Add `.polytoken/` to each project's `.gitignore` — the state dir holds
session history and device-auth tokens that shouldn't be committed, even
though `config.yaml` itself has no literal secrets.

## Ponytail integration

Every `pts` invocation copies the repository's Ponytail instructions, skills,
configuration, and Polytoken hooks into the effective per-project Polytoken
configuration. The `pre_model_turn` hook injects the active Ponytail rules
before model requests, regardless of which configured provider or model is
selected.

The default mode is `full`. Set `PONYTAIL_DEFAULT_MODE` to `off`, `lite`,
`full`, or `ultra` before launching `pts`. During a session, exact prompts such
as `ponytail ultra`, `ponytail full`, and `ponytail off` change the mode. The
portable skills can be invoked with Polytoken's skill syntax, for example
`@skill:ponytail-review`. Polytoken does not document custom slash-command
extensions, so this integration does not claim to provide native
`/ponytail-*` commands.

This is instruction-level guidance, not enforcement of model behavior. Run
`bash ponytail/tests/test_hook.sh` to check mode persistence and hook output.
