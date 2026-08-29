# FreeBSD Package Repository

Binary FreeBSD packages built for CPU architectures the official FreeBSD
package mirrors do not cover.

The packages are **cross-compiled on a FreeBSD/amd64 host** using base clang
and a target sysroot unpacked from the release's `base.txz`, then published to
GitHub Pages as a normal `pkg` repository on every push to `master`.

Cross-compiling replaced an earlier [poudriere] + [QEMU user-mode emulation]
pipeline. Emulation was both unreliable and 5–10x slower than native — slow
enough that the workflow needed a progressive package cache and a `timeout(1)`
wrapper just to make progress under GitHub Actions' 6-hour ceiling. The
cross-build runs on a KVM-accelerated guest at native speed and finishes in
minutes, so all of that is gone.

[poudriere]: https://github.com/freebsd/poudriere
[QEMU user-mode emulation]: https://wiki.freebsd.org/Ports/BuildingPackagesThroughEmulation
[Cross-Platform Action]: https://github.com/cross-platform-actions/action

## Supported targets

| Architecture | FreeBSD version | Official packages? |
|--------------|-----------------|--------------------|
| riscv64      | 15.0            | none               |
| powerpc64    | 15.0            | pkgbase only       |

`pkg.freebsd.org` publishes no ports packages for either: riscv64 is absent
entirely, and `FreeBSD:15:powerpc64` carries only `base_*` and `kmods_*`.

## Using the repository

On a matching FreeBSD system, create `/usr/local/etc/pkg/repos/custom.conf`:

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

Replace `<user>` with the GitHub user or organization hosting this repository,
and the ABI path with the one matching your system (`pkg config abi` prints
it).

## Adding things

All configuration is driven by plain-text lists. Add a line, push to `master`,
and the workflow rebuilds the repository.

| File | Purpose |
|------|---------|
| `config/pkglist` | One port origin per line (e.g. `editors/vim`) |
| `config/architectures` | One target architecture per line |
| `config/versions` | One FreeBSD version per line (e.g. `15.0`) |
| `config/ports_branch` | The pinned ports quarterly branch to build from |

### `config/architectures` format

Space-separated fields, one architecture per line:

```
<target_arch> <release_machine>
```

| Field | Description | Example |
|-------|-------------|---------|
| `target_arch` | pkg ABI architecture and ports `ARCH` | `powerpc64` |
| `release_machine` | `MACHINE` component of the release path on `download.freebsd.org`, i.e. `releases/<release_machine>/<target_arch>/` | `powerpc` |

Lines starting with `#` and blank lines are ignored.

## How the build works

Everything runs inside the FreeBSD/amd64 guest booted by the
[Cross-Platform Action], as the unprivileged `runner` user (which has
passwordless `sudo`). `scripts/cross-build.sh` orchestrates it:

1. **Sysroot.** `base.txz` for the target is fetched from
   `download.freebsd.org` and unpacked. That single download provides the
   target's `/usr/include`, `/usr/lib` and `/bin/sh` — the last of which is
   what `bsd.port.mk` reads to stamp each package's ABI. There is no toolchain
   to build, so nothing here is worth caching.
2. **Toolchain.** A five-line `share/toolchains/<arch>-clang.mk` is written
   into the target prefix, pointing `XCC`/`XCXX`/`XCPP` at base clang with
   `-target <arch>-unknown-freebsd<version>`. Base clang is already a cross
   compiler and base's `ar`/`ld`/`nm`/`objcopy`/`ranlib`/`strip` are the
   multi-target LLVM ones, so nothing needs installing. The one exception is
   `AS`: FreeBSD dropped GNU `as` from base in 13, so it is overridden to the
   compiler driver, which assembles through clang's integrated assembler.
3. **Ports tree.** The pinned quarterly branch is fetched as a tarball with
   base `fetch(1)` (no git needed).
4. **Closure.** The dependency graph is resolved and split by kind, then each
   target port is built in topological order with `make package`.
5. **Publish.** `pkg repo` builds the repository metadata over the resulting
   packages, and the tree is pulled back to the runner for the deploy job.

### How cross-compiling ports actually works, and what it costs

FreeBSD's ports framework has real cross support, but it is thin — roughly
thirty lines in `Mk/bsd.port.mk` keyed on `CROSS_TOOLCHAIN` and
`CROSS_SYSROOT`. Those set `CC` to the cross compiler with `--sysroot`, derive
`ARCH` from the toolchain name, read `OSVERSION` out of the sysroot's
`sys/param.h`, pass `--host=` to configure, and stamp the package ABI.

What it does **not** have is any separation between a build-time dependency
that must *run on the build host* (`pkgconf`, `gmake`, `msgfmt`) and one that
must be *linked into the target* (`libnghttp2`, `libintl`). pkgsrc gets that
for free from `USE_CROSS_COMPILE`; FreeBSD does not — it is the unfinished
[SoC2019 PortsSeparatedBuild] work. Left to itself, `make package` would
cross-build `pkgconf` for powerpc64 and then try to execute it.

[SoC2019 PortsSeparatedBuild]: https://wiki.freebsd.org/SummerOfCode2019Projects/PortsSeparatedBuild

Three things follow from that, and they are the whole design:

**Two prefixes, kept apart.**

| | Path | Holds |
|---|---|---|
| Host prefix | `/usr/local` | amd64 build tools, plain `pkg install` from the official mirror, reached via `PATH` |
| Target prefix | `$SYSROOT/usr/local` | cross-built target libraries and headers — this is what `LOCALBASE` points at |

`LOCALBASE` has to point into the sysroot because `USES=localbase` emits
`-isystem ${LOCALBASE}/include` and `-L${LOCALBASE}/lib`; left at `/usr/local`
those resolve to *amd64* headers and libraries. `PREFIX` is then pinned back to
`/usr/local` so the produced package still installs to the right place on the
target — without it, `PREFIX?=${LOCALBASE}` would bake the sysroot path into
every package.

**The closure is driven by the script, not the framework.** Each port's direct
`LIB_DEPENDS`/`RUN_DEPENDS` are target dependencies and get cross-built;
`BUILD_`/`EXTRACT_`/`PATCH_`/`FETCH_DEPENDS` are host tools and get
`pkg install`ed as ordinary amd64 packages. The target side is walked
depth-first to get a build order, and each port is then built with
`NO_DEPENDS=yes` so the framework's own dependency checks — which cannot tell
the two prefixes apart — never run. After each build the package is unpacked
into the sysroot so the next port finds its headers and libraries.

**Dependency metadata is generated, not detected.** The framework normally
fills a package's dependency list by locating each `LIB_DEPENDS` library on
disk and asking the *host's* pkg database who owns it
(`Mk/Scripts/actual-package-depends.sh`). Our target libraries live in the
sysroot and are registered in no database, so that probe would silently yield
an empty list — `pkg install bash` on the target would not pull in
`gettext-runtime`, and bash would not start. The script therefore overrides
`ACTUAL-PACKAGE-DEPENDS` with a list built from the closure it already
resolved.

### Guardrails

Because the two-prefix split is the fragile part, the script checks its own
work rather than trusting it:

- An **early assertion**, before any build, resolves `ARCH`, `CC`,
  `CROSS_HOST`, `LOCALBASE`, `PREFIX` and `OSVERSION` and requires each to name
  the *target*. A mis-wired `CROSS_*` fails in seconds instead of after a long
  build.
- Every packaged file is **grepped for the sysroot path**. If a port baked
  `${LOCALBASE}` into its output, the package carries an absolute
  `$SYSROOT/...` path that means nothing on the target — that fails the build
  rather than getting published.
- Every ELF in every package is checked with `readelf` for the **target's
  machine type**, and every package's recorded **ABI** must be
  `FreeBSD:<major>:<arch>`.

## Setup

GitHub Pages must be enabled on the repository with source set to **GitHub
Actions** (Settings → Pages → Build and deployment source).

## License

See [LICENSE](LICENSE).
