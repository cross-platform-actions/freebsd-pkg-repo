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
- Publish packages as immutable GitHub releases, one per architecture per
    distinct package set, instead of deploying to GitHub Pages. A release is
    additive, so a bad publish creates a bad release beside the good ones
    rather than replacing anything

### Changed
- Freeze the published GitHub Pages repository. It still serves the last
    poudriere-built set, which every existing VM image depends on — those
    images have a baked-in repo conf pointing at it and the upstream FreeBSD
    repositories disabled, so it is their only package source. The workflow no
    longer contains any job that can deploy to Pages
- Remove the Pages deploy path entirely: `extract-artifacts.sh`,
    `generate-landing-page.sh`, `generate-directory-indexes.sh` and
    `verify-site.sh`. The publish guard they protected is unnecessary once
    publishing cannot overwrite anything

[Unreleased]: https://github.com/cross-platform-actions/freebsd-pkg-repo/commits/master
