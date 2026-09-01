#!/bin/sh
# Publish the deployed package set as a GitHub release, so a copy survives
# independently of everything else that holds one.
#
# Every other copy is transient. The Actions cache is evicted after 7 days
# without a hit, build artifacts expire after 90 days, and a Pages
# deployment is a whole-site replace that keeps no history. Those three
# lapsed together once, and the published repository had to be rebuilt from
# source over three runs because no copy of it existed anywhere.
#
# One release per *distinct* package set. The set is fingerprinted by the
# sha256 of its per-package checksum manifest, so a rebuild that produces
# identical packages is skipped instead of creating a duplicate release.
#
# The asset is a tarball of the repository tree -- a restore point, not a
# pkg-consumable repository. Serving packages straight from a release would
# need the flat-layout rewrite described in the readme.
#
# Required environment:
#   GH_TOKEN - token with contents: write

set -eu

: "${GH_TOKEN:?GH_TOKEN must be set}"

archived=0

for abi_dir in _site/FreeBSD:*:*; do
    [ -d "$abi_dir" ] || continue
    abi=$(basename "$abi_dir")
    # A git tag cannot contain ':'.
    tag_base=$(echo "$abi" | tr ':' '-')

    work=$(mktemp -d)

    # Checksum manifest doubles as the fingerprint and as a way to verify a
    # restored tree later.
    (cd "$abi_dir" && find All -name '*.pkg' -type f | sort | xargs sha256sum) \
        > "$work/manifest.txt" 2>/dev/null || : > "$work/manifest.txt"
    count=$(wc -l < "$work/manifest.txt" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "$abi: no packages to archive, skipping"
        continue
    fi

    sha256sum < "$work/manifest.txt" | cut -d' ' -f1 > "$work/manifest.sha256"
    fingerprint=$(cat "$work/manifest.sha256")

    # Compare against the newest existing snapshot for this ABI.
    previous=$(gh release list --limit 100 --json tagName,createdAt \
        --jq "[.[] | select(.tagName | startswith(\"${tag_base}--\"))]
              | sort_by(.createdAt) | reverse | .[0].tagName // empty" \
        2>/dev/null || echo '')

    if [ -n "$previous" ]; then
        if gh release download "$previous" --pattern manifest.sha256 \
               --dir "$work/prev" 2>/dev/null &&
           [ "$(cat "$work/prev/manifest.sha256" 2>/dev/null)" = "$fingerprint" ]; then
            echo "$abi: identical to $previous ($count packages); nothing to archive"
            continue
        fi
    fi

    tag="${tag_base}--$(date -u +%Y%m%d-%H%M%S)"
    tarball="$work/${tag_base}.tar.gz"
    tar -C "$abi_dir" -czf "$tarball" .
    size=$(du -h "$tarball" | cut -f1)

    cat > "$work/notes.md" <<NOTES
Snapshot of the published \`${abi}\` package repository.

| | |
|---|---|
| Packages | ${count} |
| Manifest fingerprint | \`${fingerprint}\` |
| Source commit | ${GITHUB_SHA:-unknown} |
| Build run | ${GITHUB_RUN_ID:-unknown} |

This is a **restore point**, not a repository a \`pkg\` client can be pointed
at. \`${tag_base}.tar.gz\` contains the tree as deployed, so restoring means
extracting it back into \`_site/${abi}/\`.

\`manifest.txt\` lists the sha256 of every package, for verifying a restored
tree; \`manifest.sha256\` is the fingerprint of that manifest, which is what
distinguishes one snapshot from another.
NOTES

    echo "$abi: archiving $count packages ($size) as $tag"
    gh release create "$tag" \
        --title "${abi} snapshot ${tag#*--}" \
        --notes-file "$work/notes.md" \
        "$tarball" "$work/manifest.txt" "$work/manifest.sha256"

    archived=$((archived + 1))
done

echo "archived $archived snapshot(s)"
