FROM quay.io/fedora/fedora-minimal:latest
RUN microdnf install -y python3 python3-pip python3-pytest git gh jq golang zip nspr nss alsa-lib atk cups-libs gtk3 libXcomposite libXdamage libXfixes libXrandr mesa-libgbm pango podman docker docker-cli moby-engine nodejs npm poppler-utils iproute procps-ng && \
    npm install --global yaml-language-server && \
    ln -s "$(command -v yaml-language-server)" /usr/local/bin/yamlls && \
    microdnf clean all

# Nested podman/docker (running `podman`/`docker` inside pts's own container)
# need to create a further user-namespace mapping for whatever container
# *they* start. Without genuine host-level privilege that's a dead end: a
# setuid newuidmap/newgidmap can't hand out CAP_SETUID for ids beyond the one
# this container itself was mapped to ("Operation not permitted"), no matter
# which uid range is declared — which is why pts() runs this container
# --privileged (see polytoken-sandbox.sh) despite the isolation cost; without
# it, none of the below works. Given --privileged, the container gets full
# *effective* capabilities even under --userns=keep-id:size=65536 (a mapped,
# non-root uid), which is what actually makes newuidmap succeed here. Two
# pieces:
#   - newuidmap/newgidmap made setuid, and a subuid/subgid range declared for
#     the numeric uid — matching the hardcoded git identity below in
#     polytoken-sandbox.sh. keep-id:size=65536's own splicing means the
#     container's owned id space is split around the self uid (1000): ids
#     0-999 map outward one way, id 1000 is "self", ids 1001-65535 map
#     outward another way. A delegated range must be contiguous, so this uses
#     the larger chunk (1001-65535) rather than the full 65536. Deliberately
#     only ONE line here, keyed by uid — podman sums every matching
#     /etc/subuid line into the delegated range rather than treating repeats
#     as aliases, so a second line for the "will" username (tried first)
#     doubled the requested range into something the kernel rejected outright
#     ("Invalid argument").
#   - `ignore_chown_errors`, kept as a fallback: if a nested tool ever runs
#     under a plain (non-privileged) invocation of this image and falls back
#     to podman's "single mapping" mode, this stops unpacking an image layer
#     that references other numeric owners (e.g. alpine's /etc/shadow at gid
#     42) from hard-failing just because that gid isn't actually mappable.
#
# iproute (`ip`) and procps-ng (`sysctl`) are also required here — not for
# pts itself, but because nested `dockerd-rootless.sh`'s rootlesskit helper
# shells out to `ip link set lo up` and `sysctl -w net.ipv4.ip_forward=1`
# while setting up the network namespace for the nested daemon.
RUN chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap && \
    printf '1000:1001:64535\n' > /etc/subuid && \
    printf '1000:1001:64535\n' > /etc/subgid && \
    mkdir -p /etc/containers && \
    printf '[storage]\ndriver = "overlay"\n\n[storage.options]\nignore_chown_errors = "true"\n' > /etc/containers/storage.conf

# /opt/polytoken-bin backs the named volume that holds the container's own,
# independently-updatable copy of the polytoken binary (see
# polytoken-sandbox.sh). Just a normal directory here — ownership is fixed
# up to the invoking host user via a `chown 0:0` run inside a throwaway
# *plain* (non --userns=keep-id) rootless container in the pts() function
# before every run — podman's default rootless mapping identity-maps
# container uid 0 to the real host uid, which is what actually makes the
# volume writable under a later --userns=keep-id run. (`podman unshare
# chown` looks like the standard fix but is wrong here — see
# polytoken-sandbox.sh and polytoken-sandbox.md for why.) Do NOT make this
# world-writable (e.g. chmod 1777): polytoken's own self-updater refuses to
# write into a group/world-writable directory as a TOCTOU safety check, so
# that approach breaks `pts update`.
RUN mkdir -p /opt/polytoken-bin
