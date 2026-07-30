# polytoken-sandbox

Runs [polytoken](https://github.com) inside a rootless podman container for
filesystem isolation. Only the invocation directory and
`~/.job_digest/secrets.json` are exposed to the container — not the rest of
`$HOME` — while keeping full network access.

## Contents

- `polytoken-sandbox.sh` — the `pts` shell function (copy of the version
  sourced from `~/.bashrc.d/` — see setup below)
- `Containerfile` — builds `localhost/polytoken-sandbox:latest`
  (fedora-minimal + python3, pip, pytest, git, gh)
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

3. Make sure `~/.local/bin/polytoken` exists (the container mounts the host
   binary read-only, so updating polytoken on the host automatically
   updates the sandboxed version — no image rebuild needed).

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
