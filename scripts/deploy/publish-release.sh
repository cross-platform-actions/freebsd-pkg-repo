#!/bin/sh
# Publish a pkg repository as a GitHub release that pkg can install from.
#
# A release serves its assets from a single flat namespace: an asset name
# cannot contain '/', so the All/ prefix poudriere and `pkg repo` write into
# every path and repopath has nowhere to go. pkg does not need the directory
# though -- it is index driven, fetching ${url}/${repopath} for whatever the
# index names. So flattening the index and uploading the packages under bare
# names is enough to make a release a working repository.
#
# Why a release rather than Pages: a Pages deployment replaces the whole
# site, so publishing is destructive by construction and every safeguard
# around it is compensation for that. Releases are immutable and additive --
# a bad publish creates a bad release beside the good ones instead of
# replacing anything, and removing an architecture leaves its previous
# release fetchable at its tag forever.
#
# Usage: publish-release.sh <repository-directory>
#
# The directory is the canonical layout `pkg repo` produces:
#   All/*.pkg  Latest/pkg.pkg  meta  meta.conf  data.pkg  packagesite.pkg
#
# Required environment:
#   GH_TOKEN - token with contents: write
# Recommended:
#   GH_REPO  - owner/repo. Without it gh infers the repository from the
#              working directory and fails outside a checkout.
# Optional:
#   ABI      - asserted against the ABI read from the packages. A mismatch
#              is an error; it can catch a wrong call site but never cause
#              one.

set -eu

SRC="${1:?usage: publish-release.sh <repository-directory>}"
: "${GH_TOKEN:?GH_TOKEN must be set}"

[ -d "$SRC/All" ] || { echo "$SRC has no All/ directory" >&2; exit 1; }

WORK=$(mktemp -d)
FLAT="$WORK/flat"
mkdir -p "$FLAT"
trap 'rm -rf "$WORK"' EXIT

# GitHub rewrites ',' to '.' in asset filenames, which hits any package
# carrying a PORTEPOCH. Apply the substitution ourselves so the name we
# upload and the name we record in the index are equal by construction,
# rather than depending on an undocumented server-side rule.
flatten_name() {
    basename "$1" | tr ',' '.'
}

# Rewrite path/repopath wherever they appear. packagesite.yaml is one JSON
# object per line; data is a single document with a packages[] array, so the
# same filter has to reach both shapes -- hence walk() rather than a fixed
# path expression.
cat > "$WORK/flatten.jq" <<'JQ'
def flat: sub("^All/"; "") | gsub(","; ".");
walk(
  if type == "object" and (has("path") or has("repopath"))
  then (if has("path")     then .path     |= flat else . end)
     | (if has("repopath") then .repopath |= flat else . end)
  else . end
)
JQ

# jq -c streams a whole document and one-object-per-line input identically,
# so packagesite.yaml and data need no distinction here.
rewrite_index() {
    archive="$1"; member="$2"
    [ -f "$SRC/$archive" ] || { echo "missing $archive" >&2; exit 1; }
    rm -rf "$WORK/idx"; mkdir -p "$WORK/idx"
    zstd -dc "$SRC/$archive" | tar -xf - -C "$WORK/idx"
    [ -f "$WORK/idx/$member" ] || { echo "$archive has no $member" >&2; exit 1; }

    jq -c -f "$WORK/flatten.jq" < "$WORK/idx/$member" > "$WORK/idx/$member.new"
    mv "$WORK/idx/$member.new" "$WORK/idx/$member"

    if grep -q '"All/' "$WORK/idx/$member"; then
        echo "$archive still references All/ after rewriting" >&2
        exit 1
    fi
    tar -cf - -C "$WORK/idx" "$member" | zstd -q -f -o "$FLAT/$archive"
}

# The ABI comes from the packages themselves, so it cannot disagree with
# what is being published.
#
# Only architecture-dependent packages get a vote. A pure-python, pure-perl
# or data-only port is stamped FreeBSD:<major>:* and is legitimately shared
# across architectures -- 15 of the 56 packages in the poudriere-built
# riscv64 set are, so requiring every entry to agree rejects a perfectly
# good repository. Every *concrete* ABI still has to be the same one.
abi=$(zstd -dc "$SRC/packagesite.pkg" | tar -xO packagesite.yaml \
      | jq -r 'select(.abi | test("\\*") | not) | .abi' | sort -u)

case "$abi" in
    '')
        # Conceivable for a repository of nothing but architecture-independent
        # packages. Nothing in the tree can name the target, so the caller has
        # to.
        if [ -z "${ABI:-}" ]; then
            echo "every package is architecture independent; set ABI to name the target" >&2
            exit 1
        fi
        abi="$ABI" ;;
    *"
"*)
        echo "packages disagree on ABI:" >&2; echo "$abi" >&2; exit 1 ;;
esac

if [ -n "${ABI:-}" ] && [ "$ABI" != "$abi" ]; then
    echo "ABI mismatch: environment says $ABI, packages say $abi" >&2
    exit 1
fi

# A git tag cannot contain ':'.
tag_base=$(echo "$abi" | tr ':' '-')

# Latest/ is deliberately not published. It exists so `pkg bootstrap` can
# fetch Latest/pkg.pkg, a path a flat namespace cannot express, and it is a
# copy rather than a symlink -- uploading it would duplicate the package
# under a second name for no benefit. A fresh root installs pkg by fetching
# pkg-<version>.pkg directly and running pkg-static add.
count=0
: > "$WORK/packages"
for pkg in "$SRC"/All/*.pkg; do
    [ -f "$pkg" ] || continue
    name=$(flatten_name "$pkg")
    cp "$pkg" "$FLAT/$name"
    echo "$name" >> "$WORK/packages"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "no packages in $SRC/All" >&2; exit 1; }

rewrite_index packagesite.pkg packagesite.yaml
rewrite_index data.pkg        data
for f in meta meta.conf; do
    [ -f "$SRC/$f" ] || { echo "missing $f" >&2; exit 1; }
    cp "$SRC/$f" "$FLAT/$f"
done

# Every repopath the index names has to be a file we are about to upload.
# The post-upload check below catches GitHub altering a name; this catches
# the flattening and the renaming disagreeing with each other, which would
# publish an index pointing at assets that do not exist.
missing=0
for want in $(zstd -dc "$FLAT/packagesite.pkg" | tar -xO packagesite.yaml \
              | jq -r '.repopath'); do
    case "$want" in */*) echo "repopath still has a directory: $want" >&2; missing=1 ;; esac
    [ -f "$FLAT/$want" ] || { echo "index names a missing asset: $want" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "index does not match the assets" >&2; exit 1; }

# The manifest doubles as the set's fingerprint and as a way to verify a
# downloaded release later.
#
# It covers the packages and nothing else. packagesite.pkg and data.pkg also
# end in .pkg, so globbing the directory would fold the indexes into the
# fingerprint -- and `pkg repo` output is not guaranteed byte-reproducible
# (archive timestamps, compression framing), so an unchanged package set
# could fingerprint differently on every run and publish a new release each
# time. Driving the manifest from the names copied above keeps it to the
# packages regardless of what else lands in the directory.
(cd "$FLAT" && sort "$WORK/packages" | xargs sha256sum) > "$WORK/manifest.txt"
sha256sum < "$WORK/manifest.txt" | cut -d' ' -f1 > "$WORK/manifest.sha256"
fingerprint=$(cat "$WORK/manifest.sha256")
cp "$WORK/manifest.txt" "$WORK/manifest.sha256" "$FLAT/"

# One release per distinct package set: an unchanged rebuild is a no-op
# rather than either a duplicate release or a mutated one.
previous=$(gh release list --limit 100 --json tagName,createdAt \
    --jq "[.[] | select(.tagName | startswith(\"${tag_base}--\"))]
          | sort_by(.createdAt) | reverse | .[0].tagName // empty") || previous=''

if [ -n "$previous" ]; then
    if gh release download "$previous" --pattern manifest.sha256 \
           --dir "$WORK/prev" >/dev/null 2>&1 &&
       [ "$(cat "$WORK/prev/manifest.sha256" 2>/dev/null)" = "$fingerprint" ]; then
        echo "$abi: identical to $previous ($count packages); nothing to publish"
        exit 0
    fi
fi

tag="${tag_base}--$(date -u +%Y%m%d-%H%M%S)"
echo "$abi: publishing $count packages as $tag"

# Named in the release notes so the bootstrap instructions are copy-pasteable.
# ports-mgmt/pkg is in config/pkglist and the publish guard requires a package
# for every configured origin, so this is expected to exist.
pkg_asset=$(cd "$FLAT" && ls pkg-*.pkg 2>/dev/null | head -1)
[ -n "$pkg_asset" ] || { echo "no pkg-*.pkg asset; a release must be able to bootstrap itself" >&2; exit 1; }

gh release create "$tag" \
    --title "$abi $(echo "$tag" | sed 's/.*--//')" \
    --notes "Installable pkg repository for \`${abi}\`, ${count} packages.

Point pkg at this release:

\`\`\`
custom: {
    url: \"https://github.com/${GH_REPO:-OWNER/REPO}/releases/download/${tag}\",
    enabled: yes,
    signature_type: \"none\"
}
\`\`\`

\`pkg bootstrap\` cannot be used against a release: it fetches
\`Latest/pkg.pkg\`, and an asset name cannot contain a directory. On a root
with no pkg, install it by name first:

\`\`\`
fetch -o /tmp/pkg.pkg \"\$BASE/${pkg_asset}\"
cd /tmp && tar -xf pkg.pkg -s ',.*/,,g' '*/pkg-static' && ./pkg-static add /tmp/pkg.pkg
\`\`\`

Manifest fingerprint \`${fingerprint}\`." \
    "$FLAT"/*

# Confirm every asset kept the name we gave it. If GitHub ever changes what
# it rewrites, the index would point at names that no longer exist and the
# repository would be quietly broken; better to fail the publish.
gh release view "$tag" --json assets --jq '.assets[].name' | sort > "$WORK/uploaded"
(cd "$FLAT" && ls) | sort > "$WORK/expected"
if ! diff -u "$WORK/expected" "$WORK/uploaded" > "$WORK/namediff"; then
    echo "asset names were altered on upload; the index would not resolve:" >&2
    cat "$WORK/namediff" >&2
    exit 1
fi

echo "$abi: published $tag ($count packages)"
