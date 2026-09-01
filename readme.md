# FreeBSD Package Repository

Binary FreeBSD packages built for CPU architectures not covered by the official
FreeBSD package mirrors.

The packages are built with [poudriere] using [QEMU user-mode emulation] and
[Cross-Platform Action], and published to GitHub Pages on every push to
`master`.

[poudriere]: https://github.com/freebsd/poudriere
[QEMU user-mode emulation]: https://wiki.freebsd.org/Ports/BuildingPackagesThroughEmulation
[Cross-Platform Action]: https://github.com/cross-platform-actions/action

## Supported targets

| Architecture | FreeBSD version |
|--------------|-----------------|
| riscv64      | 15.0            |

## Using the repository

On a FreeBSD riscv64 system, create `/usr/local/etc/pkg/repos/custom.conf`:

```
custom: {
    url: "https://<user>.github.io/freebsd-pkg-repo/FreeBSD:15:riscv64",
    enabled: yes,
    signature_type: "none"
}
```

Then:

```sh
pkg update
pkg install bash sudo curl rsync
```

Replace `<user>` with the GitHub user or organization hosting this repository.

## Adding things

All configuration is driven by three plain-text lists. Add a line, push to
`master`, and the workflow rebuilds the repository.

| File | Purpose |
|------|---------|
| `config/pkglist` | One port origin per line (e.g. `editors/vim`) |
| `config/architectures` | One target architecture per line |
| `config/versions` | One FreeBSD version per line (e.g. `15.0`) |

### `config/architectures` format

Space-separated fields, one architecture per line:

```
<poudriere_arch> <binmiscctl_name> <qemu_binary> <elf_magic_hex> <elf_mask_hex>
```

| Field | Description | Example |
|-------|-------------|---------|
| `poudriere_arch` | `TARGET.TARGET_ARCH` for `poudriere jail -a` | `riscv.riscv64` |
| `binmiscctl_name` | Label for the binfmt entry; also used as the pkg ABI arch | `riscv64` |
| `qemu_binary` | qemu-user-static interpreter in `/usr/local/bin/` | `qemu-riscv64-static` |
| `elf_magic_hex` | ELF header bytes identifying this arch, as hex | `7f454c460201010000000000000000000200f300` |
| `elf_mask_hex` | Mask (same length as magic); `ff`=match, `00`=wildcard | `ffffffffffffff00fffffffffffffffffeffffff` |

Lines starting with `#` and blank lines are ignored.

## How it works

The workflow runs four jobs per push:

1. **generate-matrix** — reads `config/architectures` and `config/versions`
    and emits a JSON matrix (architecture x version).
2. **build** — one job per matrix entry. Starts a FreeBSD VM via
    Cross-Platform Action, installs `qemu-user-static`, registers the target
    architecture with `binmiscctl`, creates a poudriere jail, and builds
    every port in `config/pkglist`. Uploads the resulting pkg repository as
    an artifact.
3. **deploy** — merges all artifacts into one tree
    (`FreeBSD:<major>:<arch>/...`), refuses the deploy if it would publish
    fewer packages than are already live, and deploys to GitHub Pages.
4. **archive** — publishes the deployed set as a GitHub release, so a copy
    outlives the cache, the artifacts and the next deploy. See
    [Backups and recovery](#backups-and-recovery).

QEMU user-mode emulation is 5-10x slower than native, so builds may take
hours. GitHub Actions' 6-hour timeout is the hard ceiling.

## Backups and recovery

Every successful deploy publishes the package set as a GitHub release, one
per target ABI, tagged `<abi-with-dashes>--<UTC timestamp>` (for example
`FreeBSD-15-riscv64--20260901-190427`). Each release carries three assets:

| Asset | Contents |
|-------|----------|
| `FreeBSD-15-riscv64.tar.gz` | the repository tree exactly as deployed |
| `manifest.txt` | sha256 of every package, for verifying a restored tree |
| `manifest.sha256` | fingerprint of the manifest, identifying the snapshot |

A release is created only when the package set actually differs from the
newest existing snapshot, so rebuilds that produce identical packages do not
pile up duplicates.

This exists because every other copy of the repository is transient. The
Actions cache is evicted after 7 days without a hit, build artifacts expire
after 90 days, and a Pages deployment replaces the whole site with no
history. Those three lapsed at the same time once, and the published
repository had to be rebuilt from source.

To restore a snapshot:

```sh
tag=FreeBSD-15-riscv64--20260901-190427
abi=FreeBSD:15:riscv64

gh release download "$tag"
mkdir -p "_site/$abi"
tar -C "_site/$abi" -xzf FreeBSD-15-riscv64.tar.gz

# Confirm the restored tree is intact.
(cd "_site/$abi" && sha256sum -c ../../manifest.txt)
```

That reconstructs the tree. Publishing it back to Pages is still a manual
step -- there is no restore-from-release workflow input yet.

Snapshots accumulate one per distinct package set and are never pruned
automatically; delete old ones with `gh release delete` when they stop being
useful.

## Setup

GitHub Pages must be enabled on the repository with source set to **GitHub
Actions** (Settings -> Pages -> Build and deployment source).

## License

See [LICENSE](LICENSE).
