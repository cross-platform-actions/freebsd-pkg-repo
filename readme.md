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
| powerpc64    | 15.0            |

## Using the repository

On a FreeBSD powerpc64 system, create `/usr/local/etc/pkg/repos/custom.conf`:

```
custom: {
    url: "https://<user>.github.io/freebsd-pkg-repo/FreeBSD:15:powerpc64",
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
<poudriere_arch> <binmiscctl_name> <qemu_binary> <elf_magic_hex> <elf_mask_hex> [qemu_args...]
```

| Field | Description | Example |
|-------|-------------|---------|
| `poudriere_arch` | `TARGET.TARGET_ARCH` for `poudriere jail -a` | `powerpc.powerpc64` |
| `binmiscctl_name` | Label for the binfmt entry; also used as the pkg ABI arch | `powerpc64` |
| `qemu_binary` | qemu-user-static interpreter in `/usr/local/bin/` | `qemu-ppc64-static` |
| `elf_magic_hex` | ELF header bytes identifying this arch, as hex | `7f454c4602020100000000000000000000020015` |
| `elf_mask_hex` | Mask (same length as magic); `ff`=match, `00`=wildcard | `ffffffffffffff00fffffffffffffffffffeffff` |
| `qemu_args` *(optional)* | Trailing fields appended to the interpreter, split on spaces at exec time | `-cpu power9` |

Lines starting with `#` and blank lines are ignored.

## How it works

The workflow runs three jobs per push:

1. **generate-matrix** — reads `config/architectures` and `config/versions`
    and emits a JSON matrix (architecture x version).
2. **build** — one job per matrix entry. Starts a FreeBSD VM via
    Cross-Platform Action, installs `qemu-user-static`, registers the target
    architecture with `binmiscctl`, creates a poudriere jail, and builds
    every port in `config/pkglist`. Uploads the resulting pkg repository as
    an artifact.
3. **deploy** — merges all artifacts into one tree
    (`FreeBSD:<major>:<arch>/...`) and deploys it to GitHub Pages.

QEMU user-mode emulation is 5-10x slower than native, so builds may take
hours. GitHub Actions' 6-hour timeout is the hard ceiling.

## Setup

GitHub Pages must be enabled on the repository with source set to **GitHub
Actions** (Settings -> Pages -> Build and deployment source).

## License

See [LICENSE](LICENSE).
