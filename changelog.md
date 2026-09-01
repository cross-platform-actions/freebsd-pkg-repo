# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Initial release
- Build FreeBSD binary packages for riscv64 using poudriere and QEMU
    user-mode emulation
- Build targets `bash`, `sudo`, `curl` and `rsync` (with dependencies)
- Host the resulting pkg repository on GitHub Pages
- Automate builds with GitHub Actions using
    [cross-platform-actions/action](https://github.com/cross-platform-actions/action)
- Configurable build matrix via three plain-text lists:
    `config/architectures`, `config/versions` and `config/pkglist`
- Target FreeBSD 15.0 packages
- Archive every published package set as a GitHub release, so a restore
    point outlives the Actions cache, the build artifacts and the next
    deployment
- Refuse a deployment that would publish fewer packages than are already
    live, with an `allow_package_drop` override for intentional reductions
- Build the package list in cumulative chunks so a run stopped by the job
    time limit keeps the packages it already committed

[Unreleased]: https://github.com/cross-platform-actions/freebsd-pkg-repo/commits/master
