# polytoken-sandbox

Runs [polytoken](https://github.com) inside a rootless Podman container for
project-oriented filesystem isolation. PTS is intended for trusted projects,
not hostile code: nested-container support uses privileged execution, host
networking, devices, selected credentials, and disabled SELinux labels. Only
the invocation directory and explicitly approved additional mounts are exposed
from the host filesystem; the rest of `$HOME` is not mounted by default.

A repository's `.polytoken/volumes` (and `.polytoken/Containerfile`) is ignored
until the operator interactively confirms it — approval is pinned to a sha256
of the file's content, so editing it afterward requires re-approval rather than
silently reusing the old decision. Extra mounts are passed directly to Podman
and can grant broad host access, so only approve files from projects you trust.

## Contents

- `polytoken-sandbox.sh` — the `pts` shell function (copy of the version
  sourced from `~/.bashrc.d/` — see setup below)
- `Containerfile` — builds `localhost/polytoken-sandbox:latest`
  (fedora-minimal + Python tooling, git, gh, Node/npm, Codex CLI, and container tools)
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
pts                    # launch polytoken TUI in the sandbox
pts --print-session    # pass arguments through to polytoken
```

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
