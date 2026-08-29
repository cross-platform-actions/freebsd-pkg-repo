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
    resolves to the target before building, reject any package that leaks the
    sysroot path, and check each ELF's machine type and each package's ABI
- Build on pushes to any branch, so a change can be validated without
    publishing; only `master` deploys

[Unreleased]: https://github.com/cross-platform-actions/freebsd-pkg-repo/commits/master
