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
2. **Toolchain.** Three wrapper scripts —
   `/usr/local/bin/<triple>-{cc,c++,cpp}` — are generated, each exec'ing base
   clang with `-target`, `--sysroot` and the target prefix's include and
   library paths. Base clang is already a cross compiler and base's
   `ar`/`ld`/`nm`/`objcopy`/`ranlib`/`strip` are the multi-target LLVM ones, so
   nothing needs installing. A matching `share/toolchains/<arch>-clang.mk`
   names them for `bsd.port.mk`. `AS` is overridden to the compiler driver:
   FreeBSD dropped GNU `as` from base in 13, so `/usr/bin/as` does not exist.
3. **Ports tree.** The pinned quarterly branch is fetched as a tarball with
   base `fetch(1)` (no git needed).
4. **Cross configuration.** `Mk/bsd.local.mk` is written with the settings that
   have to be *appended* to framework variables, and a meson cross-file is
   generated (see below).
5. **Closure.** The dependency graph is resolved and split by kind, then each
   target port is staged, translated and packaged in topological order.
6. **Publish.** `pkg repo` builds the repository metadata over the resulting
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

Four things follow from that, and they are the whole design:

**Two prefixes, and `LOCALBASE` is left alone.**

| | Path | Holds |
|---|---|---|
| Host prefix | `/usr/local` | amd64 build tools, plain `pkg install` from the official mirror, reached via `PATH` |
| Target prefix | `$SYSROOT/usr/local` | cross-built target libraries and headers |

It is tempting to point `LOCALBASE` at the target prefix, since `USES=localbase`
emits `-isystem ${LOCALBASE}/include`. Doing so is wrong. Ports use `LOCALBASE`
as a **target runtime** path, not merely a build-time search path:
`shells/bash` compiles it into its default `PATH` and into the locations of
`profile` and `inputrc`, so that build shipped a bash whose `PATH` pointed at
the build machine's sysroot. The same assumption runs through
`USES=shebangfix`, the ~57 host tool paths in `bsd.commands.mk` and `Mk/Uses`
(`PKG_BIN`, `CMAKE_BIN`, `AUTORECONF`, `PERL`, …), and libtool's idea of where
a library will live.

`/usr/local` is simultaneously where the host's tools are and where the
target's own prefix lives at runtime, so leaving `LOCALBASE` alone makes all of
those correct at once. The target prefix instead reaches the compiler **inside
the wrapper scripts**, which carry `-isystem` and `-L` for it internally.
Keeping them out of `CFLAGS`/`LDFLAGS` keeps the sysroot path out of configure
lines, recorded build strings and generated `.pc` files — and out of libtool's
`-L` bookkeeping, which hardcodes a `RUNPATH` for any `-L` directory it does
not recognise as a system one.

The wrappers withhold `-L` from compile-only invocations: clang reports an
unused `-L` as a warning and meson promotes exactly that to an error in every
compiler probe it runs.

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

**Some settings can only be appended, and only late.** `cmake.mk` and
`meson.mk` have *no* cross support at all, so both build systems probe the
build host — cmake linked the host's amd64 `libz`, and meson executed a target
binary for its own sanity check. Their settings arrive through variables the
framework accumulates with `+=`, which a make command line would *replace*, and
`cmake.mk` runs cmake under `env -i`, so an exported `CMAKE_TOOLCHAIN_FILE`
would not survive either.

`/etc/make.conf` is read *before* the port's Makefile, which is too early: both
`dns/libpsl` (`MESON_ARGS=`) and `security/sudo` (`CONFIGURE_ARGS=`) open with
a plain `=` that discards anything appended earlier. The settings therefore
live in `Mk/bsd.local.mk`, which `bsd.port.mk` includes under `USE_LOCAL_MK`,
guarded on `_POSTMKINCLUDED` so it takes the inclusion that happens *after* the
port Makefile has been read.

### Ports that need help

Cross-compiling exposes assumptions individual ports make about the build host.
The following are carried in `Mk/bsd.local.mk` or as make variables, and each
is a symptom of the framework's missing cross support rather than a bug in the
port:

| Port | Problem | Fix |
|------|---------|-----|
| `archivers/liblz4` | Builds an HTML manual by compiling `gen_manual` *for the target* and executing it on the host | `ALL_TARGET=allmost` — upstream's "all but the manuals" |
| `security/sudo` | Its configure adds its own `-R<libdir>` | `--disable-rpath` |
| `ftp/curl` | `ssl.mk` and `gssapi.mk` hardcode `/usr`, putting the host's amd64 base headers ahead of the sysroot's | `OPENSSLINC` and `KRB5_HOME` redirected into the sysroot |
| `net/rsync` | Its configure wants a bare `python3`; the closure only installs a versioned interpreter | also install `lang/python3` |

### Guardrails

Because the sysroot boundary is the fragile part, the script checks its own
work rather than trusting it:

- An **early assertion**, before any build, resolves `ARCH`, `CC`, `HOSTCC`,
  `CROSS_HOST`, `LOCALBASE`, `PREFIX`, `PKG_BIN`, `PKG_CONFIG_LIBDIR`,
  `OSVERSION` and the `CMAKE_ARGS`/`MESON_ARGS` appends, and requires each to
  name the *target* (or, for the host tools, the host). Every one of these has
  failed silently at least once, `LOCALBASE` and the `bsd.local.mk` appends
  most expensively.
- The toolchain is **smoke-tested**: a trivial program is compiled and linked
  and its ELF machine checked, so "configured for the target" is never confused
  with "produces target binaries".
- Between staging and packaging, sysroot paths in **text** files are rewritten
  to the paths they will have on the target. `$SYSROOT/usr` *is* `/usr` there,
  so this is the standard sysroot-to-target translation — `libssh2.pc` records
  the directory cmake found OpenSSL in, and needs it.
- Before anything is published, the assembled site is **verified as a usable
  repository**: every `FreeBSD:<major>:<arch>` directory must have a non-empty
  `packagesite.pkg` and `meta.conf`, at least one package, and a package for
  every origin in `config/pkglist`. A Pages deployment replaces the whole site,
  so publishing a degraded set destroys the live repository — which is exactly
  how a terminated poudriere build once wiped it, because the old script
  swallowed its own failures and still exited 0.
- Every packaged file is then **grepped for the sysroot path**. Anything left
  is inside a binary — a `RUNPATH` or a compiled-in constant — which cannot be
  rewritten safely and is broken on the target, so it fails the build. When it
  fires it reports `readelf -d` and `strings` context, because a `RUNPATH` and
  a recorded build string need completely different fixes.
- Every ELF in every package is checked with `readelf` for the **target's
  machine type**, and every package's recorded **ABI** must be
  `FreeBSD:<major>:<arch>`.

## Setup

GitHub Pages must be enabled on the repository with source set to **GitHub
Actions** (Settings → Pages → Build and deployment source).

## License

See [LICENSE](LICENSE).
