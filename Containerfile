FROM quay.io/fedora/fedora-minimal:latest
RUN microdnf install -y python3 python3-pip python3-pytest git gh jq && microdnf clean all

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
