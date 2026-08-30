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

# --- 2. Add this repository, and scope every operation to it ----------------
# Every pkg call below is restricted with `-r crossbuilt` rather than by
# disabling the guest's own repositories. Two of those cannot work here and
# would otherwise fail the run: FreeBSD-ports 404s because no official riscv64
# ports repository exists, and the image already ships a `custom` repository
# pointing at THIS project's Pages URL -- which is the empty directory a
# terminated build left behind. Scoping also keeps the test honest about where
# the packages came from, without depending on repository names the image is
# free to change.
echo "===== CONFIGURING REPOSITORY ====="
sudo mkdir -p /usr/local/etc/pkg/repos
sudo sh -c "cat > /usr/local/etc/pkg/repos/crossbuilt.conf" <<EOF
crossbuilt: {
    url: "file://${REPO_DIR}",
    enabled: yes,
    signature_type: "none"
}
EOF
sudo pkg update -f -r crossbuilt

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
# EVERY package in the repository, not just the four leaf ports. Installing
# only those leaves their dependencies satisfied by whatever the image already
# has, so the libraries actually loaded at runtime are not the ones under test
# -- the first version of this check passed while curl reported libpsl/0.21.5,
# the image's copy, against the 0.22.0 we had just built.
ALL_PKGS="$(pkg rquery -r crossbuilt '%n' | sort)"
echo "installing: $(echo $ALL_PKGS | tr '\n' ' ')"
# -f reinstalls even when the image already has the same version, so the
# binaries under test are definitely ours. -U suppresses the automatic
# catalogue refresh, which would drag in the guest's unreachable repositories
# and fail the install for reasons that have nothing to do with these packages.
sudo pkg install -y -U -f -r crossbuilt $ALL_PKGS

echo "===== INSTALLED FROM ====="
for p in $ALL_PKGS; do
    pkg query '%n %v (from %R)' "$p"
    _repo="$(pkg query '%R' "$p")"
    [ "$_repo" = crossbuilt ] ||
        { echo "FATAL: $p came from [$_repo], not this repository" >&2; exit 1; }
done

# Every dependency our packages declare must be present and registered. Scoped
# to our own packages: `-a` would also judge whatever else the image ships, and
# fail this test for something that is not ours.
echo "===== DEPENDENCY CHECK ====="
for p in $ALL_PKGS; do
    sudo pkg check -d "$p"
done

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
# curl reports its dependencies' versions at RUNTIME, so this proves it loaded
# the libraries from this repository rather than the ones the image shipped.
# That distinction is not academic: an earlier version of this test installed
# only the leaf ports and passed while curl was reporting the image's
# libpsl/0.21.5 against the 0.22.0 sitting unused in the repository.
# pkg's version carries the port revision and epoch (0.22.0_1, 0.22.0,1);
# curl reports the upstream version only. Strip both, or the first PORTREVISION
# bump in the quarterly branch fails this gate -- and therefore the deploy --
# for a reason unrelated to the packages.
_want_psl="$(pkg query '%v' libpsl)"
_want_psl="${_want_psl%%_*}"
_want_psl="${_want_psl%%,*}"
echo "libpsl in this repository: $_want_psl"
curl --version | head -n 1 | grep -q "libpsl/$_want_psl" ||
    { echo "FATAL: curl did not load this repository's libpsl ($_want_psl)" >&2
      exit 1; }
echo "curl is linked against this repository's libpsl"

bash -c 'set -e; x=0; for i in 1 2 3; do x=$((x + i)); done; [ "$x" = 6 ] && echo "bash arithmetic OK"'
curl -fsS --max-time 60 https://www.freebsd.org/ -o /dev/null && echo "curl HTTPS OK"
rsync -a --version >/dev/null && echo "rsync OK"

echo "===== OK: every package installed from this repository and ran ====="
