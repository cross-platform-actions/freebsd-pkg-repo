#!/bin/sh
# Install this repository's packages on a REAL target and run them.
#
# Runs INSIDE a FreeBSD/riscv64 guest booted by cross-platform-actions/action.
# Everything else in this project verifies that the packages were *built*
# correctly -- right ABI, right ELF machine, no sysroot paths, plausible
# dependency metadata. None of that proves they execute. Cross-compiled
# binaries can be perfectly well-formed and still fail on first run, so this is
# the only check that actually closes the loop.
#
# riscv64 is used because it is the only target here with a published guest
# image; powerpc64 has none, which is much of why its packages are wanted in
# the first place. The two are built by the identical pipeline, so a riscv64
# pass is meaningful evidence for powerpc64 without being proof of it.
#
# The guest already ships bash, sudo, curl and rsync, so this deliberately
# force-reinstalls them FROM THIS REPOSITORY and then checks that what is
# installed came from here -- otherwise the test would pass on the image's own
# packages and prove nothing.
#
# Required environment variables:
#   REPO_DIR - directory holding the pkg repository (All/, meta.conf,
#              packagesite.pkg), reachable inside the guest.

set -eux

PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

REPO_DIR="${REPO_DIR:?REPO_DIR must be set}"
[ -s "$REPO_DIR/packagesite.pkg" ] ||
    { echo "FATAL: $REPO_DIR is not a pkg repository" >&2; exit 1; }

PKGS="bash sudo curl rsync"

# --- 1. The guest must match the packages we built -------------------------
echo "===== TARGET ====="
uname -a
ABI="$(pkg config abi)"
echo "pkg ABI: $ABI"
[ "$ABI" = "FreeBSD:15:riscv64" ] ||
    { echo "FATAL: guest ABI is [$ABI], packages are FreeBSD:15:riscv64" >&2
      exit 1; }

# --- 2. Point pkg at this repository, and ONLY at it ------------------------
# The stock FreeBSD repository is disabled so nothing can be silently satisfied
# from elsewhere -- there is no official riscv64 ports repository anyway, so
# leaving it enabled would only make `pkg update` fail.
echo "===== CONFIGURING REPOSITORY ====="
sudo mkdir -p /usr/local/etc/pkg/repos
sudo sh -c 'cat > /usr/local/etc/pkg/repos/FreeBSD.conf' <<'EOF'
FreeBSD: { enabled: no }
EOF
sudo sh -c "cat > /usr/local/etc/pkg/repos/crossbuilt.conf" <<EOF
crossbuilt: {
    url: "file://${REPO_DIR}",
    enabled: yes,
    signature_type: "none"
}
EOF
sudo pkg update -f

# What the catalogue offers, which also proves packagesite.pkg parses.
echo "===== CATALOGUE ====="
pkg rquery -r crossbuilt '%n %v' | sort

# --- 3. Recorded dependencies -----------------------------------------------
# The framework derives these by asking the BUILD HOST's package database who
# owns each library, which knows nothing about a cross build's sysroot; the
# build script generates them from the resolved closure instead. If that were
# wrong the list would be empty here, and installing curl would not pull in
# what it links against.
echo "===== RECORDED DEPENDENCIES ====="
for p in $PKGS; do
    echo "--- $p ---"
    pkg rquery -r crossbuilt '%dn-%dv' "$p" || true
done
if [ -z "$(pkg rquery -r crossbuilt '%dn' curl)" ]; then
    echo "FATAL: curl records no dependencies; the manifest is empty" >&2
    exit 1
fi

# --- 4. Install from this repository ----------------------------------------
# -f forces reinstall even when the image already has the same version, so the
# binaries under test are definitely ours.
echo "===== INSTALLING ====="
sudo pkg install -y -f -r crossbuilt $PKGS

echo "===== INSTALLED FROM ====="
for p in $PKGS; do
    pkg query '%n %v (from %R)' "$p"
    _repo="$(pkg query '%R' "$p")"
    [ "$_repo" = crossbuilt ] ||
        { echo "FATAL: $p came from [$_repo], not this repository" >&2; exit 1; }
done

# Every dependency of every installed package must be present and registered.
echo "===== DEPENDENCY CHECK ====="
sudo pkg check -d -a

# --- 5. Actually run them ---------------------------------------------------
# The whole point: cross-compiled binaries that link and install can still be
# built for the wrong ABI variant, miss a shared library, or abort on start.
echo "===== EXECUTING ====="
bash -c 'echo "bash runs: ${BASH_VERSION}"'
curl --version | head -n 1
rsync --version | head -n 1
sudo -V | head -n 1

# Something slightly more than --version: bash actually interpreting a script,
# and curl exercising its TLS and compression stack against a real host.
bash -c 'set -e; x=0; for i in 1 2 3; do x=$((x + i)); done; [ "$x" = 6 ] && echo "bash arithmetic OK"'
curl -fsS --max-time 60 https://www.freebsd.org/ -o /dev/null && echo "curl HTTPS OK"
rsync -a --version >/dev/null && echo "rsync OK"

echo "===== OK: every package installed from this repository and ran ====="
