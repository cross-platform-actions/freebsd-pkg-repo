# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Initial release
- Cross-compile FreeBSD binary packages on a FreeBSD/amd64 host, using base
    clang and a target sysroot unpacked from the release's `base.txz`
- Build targets `bash`, `sudo`, `curl`, `rsync` and `pkg` (with dependencies)
- Target `riscv64` and `powerpc64`, neither of which has official ports
    packages
- Host the resulting pkg repository on GitHub Pages
- Automate builds with GitHub Actions using
    [cross-platform-actions/action](https://github.com/cross-platform-actions/action)
- Configurable build matrix via four plain-text lists:
    `config/architectures`, `config/versions`, `config/pkglist` and
    `config/ports_branch`
- Pin the ports tree to a quarterly branch so builds are reproducible
- Target FreeBSD 15.0 packages
- Validate every package before publishing: assert the cross configuration
    resolves to the target before building, smoke-test the toolchain by
    compiling and linking a binary, translate staged sysroot paths into their
    target equivalents, reject any package that still leaks one, and check each
    ELF's machine type and each package's ABI
- Generate each package's dependency metadata from the resolved closure, since
    the ports framework derives it by asking the build host's pkg database,
    which knows nothing of the target libraries in the sysroot
- Supply the cross configuration the ports framework lacks for cmake and meson,
    and carry the handful of per-port workarounds cross-compiling requires
    (see the readme)
- Build on pushes to any branch, so a change can be validated without
    publishing; only `master` deploys
- Refuse to deploy an incomplete package set. A GitHub Pages deployment
    replaces the whole site, so publishing a degraded set destroys the live
    repository; the site is now checked for a usable `packagesite.pkg` and
    `meta.conf` and a package for every origin in `config/pkglist` before
    anything is published

[Unreleased]: https://github.com/cross-platform-actions/freebsd-pkg-repo/commits/master
