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
ARCH_FILE="$REPO_ROOT/config/architectures"
VERSIONS_FILE="$REPO_ROOT/config/versions"

[ -d _site ] || { echo "FATAL: no _site directory to verify" >&2; exit 1; }

# strip_comments FILE -- the shared filter for the plain-text config lists.
strip_comments() {
    grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$'
}

# Which ABI directories MUST be present. Counting the ones that happen to exist
# is not enough: an arch dropped from config/architectures, or a matrix leg
# that produced no artifact for any reason short of a job failure, would leave
# a smaller site that then replaces the whole published one -- the exact wipe
# this file exists to prevent, and which an earlier version of it let through
# because it only required at least one directory.
expected_abis=""
while IFS= read -r version; do
    [ -n "$version" ] || continue
    major="${version%%.*}"
    while IFS= read -r arch_line; do
        [ -n "$arch_line" ] || continue
        arch="$(echo "$arch_line" | awk '{print $1}')"
        expected_abis="$expected_abis FreeBSD:${major}:${arch}"
    done <<EOF
$(strip_comments "$ARCH_FILE")
EOF
done <<EOF
$(strip_comments "$VERSIONS_FILE")
EOF

[ -n "$expected_abis" ] ||
    { echo "FATAL: config/architectures x config/versions is empty" >&2; exit 1; }
echo "expecting:$expected_abis"

# The package name a port origin produces is not always its directory name, but
# it is for everything this repository builds, and the alternative -- shipping
# the expected names out of the guest -- would put a private file in the
# published tree. A mismatch fails loudly here rather than silently publishing
# a set that is missing something, which is the behaviour we want either way.
expected="$(strip_comments "$PKGLIST" | sed -e 's|.*/||' -e 's|@.*||')"

status=0

for abi in $expected_abis; do
    dir="_site/$abi"
    echo "===== verifying $abi ====="
    if [ ! -d "$dir" ]; then
        echo "FATAL: $abi is configured but absent from the site;" \
             "deploying would remove it from the published repository" >&2
        status=1
        continue
    fi

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
    # A NON-EMPTY package must exist. Testing only for existence would accept a
    # zero-byte file, which is the shape a truncated or interrupted copy leaves
    # behind -- and every other check here already uses -s.
    for name in $expected; do
        found=""
        for pkgfile in "$dir"/All/"$name"-[0-9]*.pkg; do
            [ -s "$pkgfile" ] && found="$pkgfile" && break
        done
        if [ -n "$found" ]; then
            echo "  OK: $name ($(basename "$found"))"
        else
            echo "FATAL: $abi has no non-empty package for requested origin" \
                 "'$name'" >&2
            status=1
        fi
    done
done

if [ "$status" -ne 0 ]; then
    echo "===== REFUSING TO DEPLOY: the package set is incomplete =====" >&2
    exit 1
fi
echo "===== OK: every configured package set verified, safe to deploy:" \
     "$expected_abis ====="
