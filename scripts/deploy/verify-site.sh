#!/bin/sh
# Refuse to publish a degraded package set.
#
# A GitHub Pages deployment REPLACES the whole site: the uploaded artifact is
# the site, so anything absent from it disappears. That is how a terminated
# build once wiped the live repository -- the old poudriere script swallowed
# its own failures (`poudriere bulk ... || echo`), so a killed run still exited
# 0, published an empty FreeBSD:15:riscv64 directory, and took the packages
# with it.
#
# That specific hole is closed upstream of here: cross-build.sh exits non-zero
# unless every requested origin produced a package, and the deploy job's
# `needs: build` is satisfied by neither a failed nor a cancelled matrix job.
# What remains is a run that legitimately succeeds while producing LESS than
# expected -- a truncated config/pkglist, an arch quietly dropped from
# config/architectures -- which would still shrink the published repository.
#
# So this is the last gate before deploying: every ABI directory has to be a
# repository pkg would actually accept, and it has to contain a package for
# every origin the configuration asked for.
#
# Runs on the Linux runner, so must be plain sh-compatible.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PKGLIST="$REPO_ROOT/config/pkglist"

[ -d _site ] || { echo "FATAL: no _site directory to verify" >&2; exit 1; }

# The package name a port origin produces is not always its directory name, but
# it is for everything this repository builds, and the alternative -- shipping
# the expected names out of the guest -- would put a private file in the
# published tree. A mismatch fails loudly here rather than silently publishing
# a set that is missing something, which is the behaviour we want either way.
expected="$(grep -v '^[[:space:]]*#' "$PKGLIST" | grep -v '^[[:space:]]*$' |
            sed -e 's|.*/||' -e 's|@.*||')"

status=0
abi_count=0

for dir in _site/FreeBSD:*:*; do
    [ -d "$dir" ] || continue
    abi_count=$((abi_count + 1))
    abi="$(basename "$dir")"
    echo "===== verifying $abi ====="

    # pkg needs the catalogue and the repository metadata. `pkg repo` writes
    # meta.conf on this version; accept `meta` too rather than pin the guard to
    # one pkg release.
    if [ ! -s "$dir/packagesite.pkg" ]; then
        echo "FATAL: $abi has no non-empty packagesite.pkg;" \
             "pkg would reject this repository" >&2
        status=1
    fi
    if [ ! -s "$dir/meta.conf" ] && [ ! -s "$dir/meta" ]; then
        echo "FATAL: $abi has neither a non-empty meta.conf nor meta" >&2
        status=1
    fi

    count="$(find "$dir/All" -type f -name '*.pkg' 2>/dev/null | wc -l | tr -d ' ')"
    echo "  $count packages in All/"
    if [ "$count" -eq 0 ]; then
        echo "FATAL: $abi contains no packages" >&2
        status=1
    fi

    # Every requested origin must be present. The version is required to start
    # with a digit so that a name is not matched by a longer one (pkg- must not
    # be satisfied by pkgconf-).
    for name in $expected; do
        if ls "$dir"/All/"$name"-[0-9]*.pkg >/dev/null 2>&1; then
            echo "  OK: $name"
        else
            echo "FATAL: $abi has no package for requested origin '$name'" >&2
            status=1
        fi
    done
done

if [ "$abi_count" -eq 0 ]; then
    echo "FATAL: _site contains no FreeBSD:<major>:<arch> directory --" \
         "deploying this would empty the repository" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo "===== REFUSING TO DEPLOY: the package set is incomplete =====" >&2
    exit 1
fi
echo "===== OK: $abi_count package set(s) verified, safe to deploy ====="
