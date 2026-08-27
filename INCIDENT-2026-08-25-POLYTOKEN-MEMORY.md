# Polytoken memory exhaustion incident — 2026-08-25

## Summary

The workstation had 62 GiB of physical memory and 16 GiB of zram swap. At the
start of the investigation, 44 GiB of RAM was in use and swap was effectively
full (about 15.9 GiB used).

The primary consumer was a long-running Polytoken daemon for
`/var/home/will/work/gates-of-europa`:

- PID: `2558433`
- session: `097fqn-spree`
- start time: 2026-08-22 18:37:56
- resident memory: about 16.2 GiB
- swapped memory: about 11.6 GiB
- total observed Polytoken usage across six processes: about 16.8 GiB resident
  and 12.0 GiB swapped

The daemon had originally been launched from a KDE Konsole tab. Closing the tab
did not stop it. Its process remained in the Konsole-created systemd scope and
was reparented to the user systemd manager. The cgroup path described its
origin, not a still-open terminal.

The process executable was reported as
`/var/home/will/.local/bin/polytoken (deleted)`. This means the on-disk binary
had been replaced or removed after the process started; Linux retained the old
executable image for the live process.

Other Polytoken processes were associated with:

- `/var/home/will/work/career-ops`
- `/home/will/work/photo-uploader` (containerized)
- `/var/home/will/.bashrc.d/polytoken-sandbox` (containerized)

The large `gates-of-europa` process was a host process, not the containerized
sandbox instance. Containerization would nevertheless have limited the impact
if an equivalent runaway occurred inside PTS.

## What was established, and what was not

The measurements establish that the `gates-of-europa` daemon retained most of
the Polytoken RAM and swap and survived its launching terminal. They do not, by
themselves, identify why Polytoken allocated or retained that memory. Possible
causes such as session-history growth, an unbounded cache, task fan-out, or a
memory leak require application metrics, heap profiling, and logs from the
affected session. This incident should not assign one of those causes without
that evidence.

The lifecycle issue is clearer: a daemon is intentionally capable of surviving
its launching shell, so terminal closure is not a reliable ownership or cleanup
mechanism.

## Remediation performed

All six processes named exactly `polytoken` were first sent `SIGTERM`. None had
exited after the grace period. Five were then killed, and the final runaway PID
was explicitly sent `SIGKILL`.

After PID `2558433` exited:

- RAM in use fell from about 44 GiB to 31 GiB.
- available RAM rose from about 18 GiB to 31 GiB.
- zram swap use fell from about 15.7 GiB to 7.7 GiB.

The final process briefly appeared as a zero-RSS zombie while its parent had not
yet reaped it. A zombie retains a process-table entry but consumes no application
memory.

Swap did not return to zero because other applications still had swapped pages,
and Linux does not eagerly move every live page back into RAM merely because
memory pressure has ended.

## Recommended PTS improvements

### 1. Add a hard memory boundary

The current launcher uses `podman run --rm -it` without a memory limit. `--rm`
only removes the container after it exits; it neither limits memory nor ensures
that the workload exits when a terminal disappears.

Add configurable Podman limits, with defaults appropriate for this 62 GiB host.
A reasonable starting policy is:

```sh
--memory=12g
--memory-swap=16g
--pids-limit=2048
```

The exact memory ceiling should be tuned from normal peak usage. It should be
high enough for expected agent workloads but low enough that one PTS instance
cannot exhaust host RAM and zram. Expose environment overrides for unusually
large jobs rather than silently removing the boundary.

### 2. Give each container a stable identity

Assign a unique, predictable `--name` and record the container ID. This makes
`podman ps`, `podman stats`, `podman stop`, and incident attribution reliable.
The name should include a filesystem-safe project identifier plus a uniqueness
component so concurrent sessions do not collide.

Avoid `--replace` as the default: silently replacing an active container could
destroy a legitimate concurrent session.

### 3. Make the container the lifecycle boundary

Add `--init` so PID 1 forwards signals and reaps orphaned descendants. Ensure
Polytoken remains the `exec`-replaced foreground process, as the current
`seed_and_exec` script already does. Do not daemonize it outside the container.

The launcher should install cleanup handling around `podman run`: on shell
interrupt or termination, send `podman stop --time <grace>` to the recorded
container, then use `podman kill` only if the grace period expires. Cleanup must
target the recorded container ID, never a broad name or all Polytoken processes.

`SIGHUP` should be handled explicitly as well as `INT` and `TERM`, because a
terminal closing commonly presents as a hangup. Test this rather than assuming
the interactive Podman client always receives and propagates the signal.

### 4. Add operator commands and visibility

Provide small lifecycle commands such as:

- `pts ps` — list PTS containers with project, status, age, and memory
- `pts stop [project-or-container]` — graceful stop with bounded escalation
- `pts stats` — show live container memory, CPU, PID, and block-I/O use
- `pts prune` — remove only stopped PTS containers after confirmation

At launch, print the container name/ID and effective resource limits. This turns
a future report from “Polytoken is using memory” into an immediately attributable
project and session.

### 5. Preserve diagnostics before forced termination

When a container approaches its memory limit, retain enough evidence to debug
the application-level cause:

- container name/ID, project, Polytoken session ID, and start time
- `podman stats --no-stream`
- process RSS and swap ranking inside the container
- recent Polytoken logs
- cgroup memory counters, including peak and OOM events

Do not copy credentials or full prompt/session contents into an incident bundle.
Logs should have rotation or size limits so diagnostics cannot become a separate
disk-exhaustion problem.

### 6. Add a regression check

The smallest useful lifecycle test should:

1. launch a disposable PTS-like container with a child process,
2. simulate interrupt and terminal hangup paths,
3. assert that the container and child disappear within the grace period, and
4. verify that the configured memory and PID limits appear in `podman inspect`.

This tests the failure mode directly. A test that only checks `--rm` after normal
exit would not cover this incident.

## Suggested implementation order

1. Add configurable memory, swap, and PID limits.
2. Add a unique container name/ID and print it at startup.
3. Add targeted signal cleanup and `--init`.
4. Add the lifecycle regression test.
5. Add `pts ps`, `pts stop`, and `pts stats` once the identity scheme is stable.
6. Profile Polytoken separately if abnormal growth recurs within the new limit.

The first four items provide containment and deterministic cleanup without
requiring a diagnosis of Polytoken's internal allocation behavior.

## Remediation ledger

| Key | Status | Implementation path/symbol | Regression test | Documentation |
|---|---|---|---|---|
| INCIDENT-1 | implemented | `polytoken-sandbox.sh:_pts_project_hash`, managed labels | `test_slug_hash` | `PTS-CONTAINER.md` identity section |
| INCIDENT-2 | implemented | `polytoken-sandbox.sh:podman create` resource flags | `test_no_unsafe_operations` | `README.md` limits |
| INCIDENT-3 | implemented | `polytoken-sandbox.sh:--init` and inner `exec` | `test_no_unsafe_operations` | `PTS-CONTAINER.md` runtime |
| INCIDENT-4 | implemented | `polytoken-sandbox.sh:_pts_stop_exact` | `test_no_unsafe_operations` | `PTS-CONTAINER.md` signal behavior |
| INCIDENT-5 | implemented | `polytoken-sandbox.sh:_pts_diag` | `test_docs_contract` | `PTS-CONTAINER.md` diagnostics |
| INCIDENT-6 | documented-upstream-runbook | upstream profiling required on recurrence | `test_docs_contract` | this report, profiling guidance above |
| REQUEST-OWNED-CLEANUP | implemented | `polytoken-sandbox.sh:_pts_owner_signal` | `test_no_unsafe_operations` | `PTS-CONTAINER.md` operator commands |
| REQUEST-PRESERVE-DETACH | implemented | managed running-state retention | `test_docs_contract` | `README.md` detach/continue distinction |

The incident measurements establish lifecycle impact and runaway retention, not
an internal Polytoken allocation cause. Provider-free live-session and durable-
continue integration proofs remain a blocking prerequisite for claiming those
specific end-to-end acceptance criteria when the compatible executable/image
fixture is available.
