#!/bin/sh
# Cross-build FreeBSD binary packages for an architecture the official package
# mirrors do not cover (riscv64, powerpc64).
#
# Runs INSIDE the FreeBSD/amd64 guest booted by cross-platform-actions/action,
# as the unprivileged `runner` user (which has passwordless sudo). The guest is
# KVM-accelerated, so the compiler runs at native speed -- unlike the QEMU
# user-mode emulation this replaced, which was both slow and unreliable.
#
# Required environment variables:
#   TARGET_ARCH     - pkg ABI architecture / ports ARCH (e.g. powerpc64)
#   RELEASE_MACHINE - MACHINE component of the release path on
#                     download.freebsd.org (e.g. powerpc)
#   FREEBSD_VERSION - target FreeBSD version (e.g. 15.0)
#   PORTS_BRANCH    - pinned ports branch (e.g. 2026Q3)
#   WORKSPACE       - shared workspace dir (== GITHUB_WORKSPACE). Synced both
#                     ways, so it is the only channel to/from the host runner.
#
# ---------------------------------------------------------------------------
# How this works, and why it is shaped this way
#
# FreeBSD's ports framework has real cross support, but it is thin: about
# thirty lines in Mk/bsd.port.mk keyed on CROSS_TOOLCHAIN + CROSS_SYSROOT. They
# set CC to the cross compiler with --sysroot, derive ARCH from the toolchain
# name, read OSVERSION out of the sysroot's sys/param.h, pass --host= to
# configure and stamp packages with the target ABI (ABI_FILE=$SYSROOT/bin/sh).
#
# What the framework does NOT have is any separation between a build-time
# dependency that must RUN on the build host (pkgconf, gmake, msgfmt) and one
# that must be LINKED INTO the target (libnghttp2, libintl). pkgsrc gets that
# for free from USE_CROSS_COMPILE; FreeBSD does not -- it is the unfinished
# SoC2019 "PortsSeparatedBuild" work. Left to itself, `make package` would
# happily cross-build pkgconf for powerpc64 and then try to execute it.
#
# So this script drives the dependency closure itself (step 6) and builds each
# port with NO_DEPENDS=yes, which switches the framework's dependency machinery
# off entirely.
#
# That leaves two prefixes:
#
#   host prefix    /usr/local              amd64 build tools, plain
#                                          `pkg install` from the official
#                                          amd64 repo, reached via PATH
#   target prefix  $SYSROOT/usr/local      cross-built target libraries and
#                                          headers
#
# LOCALBASE is left at /usr/local and is NOT repointed at the target prefix.
# That was tried, and it is wrong: ports use LOCALBASE as a TARGET RUNTIME
# path, not merely as a build-time search path. shells/bash compiles it into
# its default PATH and into the locations of profile and inputrc, so a build
# with LOCALBASE=$SYSROOT/usr/local shipped a bash whose PATH pointed at the
# build machine's sysroot. The same assumption runs through USES=shebangfix
# (shebang lines), Mk/bsd.commands.mk and ~50 Mk/Uses variables (host tool
# paths), and libtool's idea of where a library will live. /usr/local is
# simultaneously where the host's tools are and where the target's own prefix
# will be, so leaving it alone makes every one of those uses correct at once.
#
# The target prefix instead reaches the compiler through the wrapper scripts in
# step 2, which carry -isystem/-L for it internally. Because those never appear
# in CFLAGS, LDFLAGS or a configure line, the sysroot path stays out of
# recorded build strings, generated .pc files, and libtool's -L bookkeeping
# (libtool hardcodes a RUNPATH for any -L directory it does not recognise as a
# system one, which was stamping $SYSROOT/usr/lib into sudo's libraries).
#
# Step 7 still greps every packaged file for the sysroot path and fails the
# build rather than publishing it, since that is the invariant this whole
# arrangement exists to preserve.
#
# The framework normally fills a package's
# dependency list by locating each LIB_DEPENDS library on disk and asking the
# HOST's pkg database who owns it (Mk/Scripts/actual-package-depends.sh). Our
# target libraries live in the sysroot and are registered in no database at
# all, so that lookup would silently yield an EMPTY deps list -- `pkg install
# bash` on the target would then not pull in gettext-runtime, and bash would
# not start. Step 7 therefore overrides ACTUAL-PACKAGE-DEPENDS with a
# pre-computed list built from the closure resolved in step 6, which is
# knowledge we already have and is more direct than the file-ownership probe.
#
# Exit status: 0 only if every origin in config/pkglist produced a package of
# the target architecture.

set -eux

# Non-interactive shells get a minimal PATH; add the sbin and pkg dirs so
# sudo, pkg and the host build tools all resolve.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH must be set}"
RELEASE_MACHINE="${RELEASE_MACHINE:?RELEASE_MACHINE must be set}"
FREEBSD_VERSION="${FREEBSD_VERSION:?FREEBSD_VERSION must be set}"
PORTS_BRANCH="${PORTS_BRANCH:?PORTS_BRANCH must be set}"
WORKSPACE="${WORKSPACE:?WORKSPACE must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKGLIST="$SCRIPT_DIR/../config/pkglist"

MAJOR_VERSION="${FREEBSD_VERSION%%.*}"
TARGET_ABI="FreeBSD:${MAJOR_VERSION}:${TARGET_ARCH}"
# A NO_ARCH package is stamped with a wildcard arch instead of the target's.
NOARCH_ABI="FreeBSD:${MAJOR_VERSION}:*"
TRIPLE="${TARGET_ARCH}-unknown-freebsd${FREEBSD_VERSION}"
CROSS_TOOLCHAIN="${TARGET_ARCH}-clang"

# readelf's `Machine:` line for this target. Used twice: to smoke-test the
# toolchain before anything is built, and to prove every packaged binary really
# is for the target. An unlisted arch skips both checks rather than failing.
#
# MESON_* describe the same target to meson's cross file (step 4.5). meson
# names CPU families its own way -- powerpc64 is "ppc64" there -- and it has no
# way to infer endianness, so both are spelled out per arch.
case "$TARGET_ARCH" in
    riscv64)
        ELF_MACHINE="RISC-V"
        MESON_CPU_FAMILY=riscv64; MESON_ENDIAN=little ;;
    powerpc64)
        ELF_MACHINE="PowerPC64"
        MESON_CPU_FAMILY=ppc64;   MESON_ENDIAN=big ;;
    powerpc64le)
        ELF_MACHINE="PowerPC64"
        MESON_CPU_FAMILY=ppc64;   MESON_ENDIAN=little ;;
    aarch64)
        ELF_MACHINE="AArch64"
        MESON_CPU_FAMILY=aarch64; MESON_ENDIAN=little ;;
    *)
        ELF_MACHINE=""
        MESON_CPU_FAMILY="$TARGET_ARCH"; MESON_ENDIAN=little ;;
esac

SYSROOT="$HOME/sysroot.$TARGET_ARCH"
TARGET_LOCALBASE="$SYSROOT/usr/local"
PORTSDIR="$HOME/ports"
PACKAGES="$HOME/packages"
PUBLISH_DIR="$HOME/publish"
# Package identity (name/origin/version) and direct target dependencies for
# every port in the closure, recorded once during step 6 so step 7 can build
# each package's manifest dependency block without re-running make.
METAFILE="$HOME/port-meta"
MANIFEST_DEPS_DIR="$HOME/manifest-deps"

# fetch_retry OUTFILE URL...: download OUTFILE trying each candidate URL in
# order, over several rounds with backoff. download.FreeBSD.org and codeload
# both hiccup occasionally, and a single failed fetch would waste the whole
# run; the caller passes a fallback URL where one exists.
fetch_retry() {  # $1 = output file; $2.. = candidate URLs (preference order)
    _out="$1"; shift
    _round=1
    while :; do
        for _url in "$@"; do
            if fetch -o "$_out" "$_url"; then return 0; fi
            echo "fetch failed (round $_round): $_url" >&2
        done
        if [ "$_round" -ge 3 ]; then
            echo "FATAL: all mirrors failed after $_round rounds for $_out" >&2
            return 1
        fi
        echo "all mirrors failed round $_round, retrying in $((_round * 15))s" >&2
        sleep "$((_round * 15))"
        _round=$((_round + 1))
    done
}

# --- 0. Verify passwordless sudo --------------------------------------------
# Needed to extract base.txz (root-owned files carrying file flags) and to
# install the host build tools. Fail loudly here, not deep in a build.
echo "===== VERIFYING PASSWORDLESS SUDO ====="
id
sudo -n true

# --- 1. Target sysroot ------------------------------------------------------
# FreeBSD publishes a ready-made target root for every release, so unlike the
# NetBSD side of this project there is no toolchain to build and nothing worth
# caching: base.txz is a ~200 MB download that unpacks in seconds and gives us
# the target's /usr/include, /usr/lib and -- needed by bsd.port.mk to stamp the
# package ABI -- /bin/sh.
#
# --no-fflags: base.txz sets schg on some binaries, which would make the tree
# undeletable and block later writes under $SYSROOT.
echo "===== FETCHING TARGET SYSROOT ($TARGET_ABI) ====="
sudo rm -rf "$SYSROOT"
mkdir -p "$SYSROOT"
cd "$HOME"
fetch_retry base.txz \
    "https://download.freebsd.org/releases/${RELEASE_MACHINE}/${TARGET_ARCH}/${FREEBSD_VERSION}-RELEASE/base.txz" \
    "https://download.freebsd.org/ftp/releases/${RELEASE_MACHINE}/${TARGET_ARCH}/${FREEBSD_VERSION}-RELEASE/base.txz"
sudo tar -xf base.txz -C "$SYSROOT" --no-fflags
rm -f base.txz

[ -f "$SYSROOT/usr/include/sys/param.h" ] ||
    { echo "FATAL: sysroot has no usr/include/sys/param.h" >&2; exit 1; }
[ -f "$SYSROOT/bin/sh" ] ||
    { echo "FATAL: sysroot has no bin/sh (needed for the package ABI)" >&2; exit 1; }

# base.txz has to be unpacked as root (its files are root-owned and carry
# flags), but from here on the sysroot is only ever read for headers and
# libraries and written to with cross-built packages -- all as the
# unprivileged user. Hand the whole tree over rather than just the target
# prefix: step 7 unpacks each package from the sysroot root, and tar restores
# the mtime of every directory it traverses, so a root-owned $SYSROOT or
# $SYSROOT/usr fails with "Can't restore time: Operation not permitted".
sudo mkdir -p "$TARGET_LOCALBASE"
sudo chown -R "$(id -u):$(id -g)" "$SYSROOT"

# --- 2. Cross toolchain -----------------------------------------------------
# bsd.port.mk does
# `.include "${LOCALBASE}/share/toolchains/${CROSS_TOOLCHAIN}.mk"`, so the
# toolchain description has to live in the target prefix. The ports tree ships
# such files via devel/freebsd-gcc13 (which does have a powerpc64 flavor), but
# base clang on FreeBSD 15 is already a cross compiler for both of our targets
# and base's binutils are the multi-target LLVM ones (ld is lld;
# nm/objcopy/strip/ar/ranlib are llvm-*). So write the five lines ourselves and
# install nothing. The one tool base does NOT have is `as`; step 4 overrides it.
#
# CROSS_TOOLCHAIN must be "<arch>-<something>": bsd.port.mk derives
# ARCH=${CROSS_TOOLCHAIN:C,-.*$,,} from it.
#
# If clang turns out to be the wrong choice for some target, the fallback is
# `pkg install freebsd-gcc13-<arch>` plus CROSS_TOOLCHAIN=<arch>-gcc13, which
# installs an equivalent file naming a real prefixed cross binutils.
echo "===== WRITING CROSS TOOLCHAIN ($CROSS_TOOLCHAIN) ====="

# The compiler is exposed as three wrapper scripts rather than as
# "cc -target ... --sysroot=...", because a compiler variable carrying
# arguments is not portable across build systems: cmake rejects it outright
# ("The CMAKE_C_COMPILER ... is not a full path to an existing compiler tool"),
# which is what killed archivers/brotli and security/libssh2. A single argv[0]
# that any build system can exec keeps cmake, meson and autotools all happy.
#
# Baking --sysroot into the wrapper has a second benefit: bsd.port.mk would
# otherwise append it to CC itself, putting the build machine's sysroot path
# into every configure line and every recorded CFLAGS string.
#
# The wrappers live in the host prefix (they are amd64 programs, and this is
# where devel/freebsd-gcc13 would install its equivalents), never in the
# sysroot, so their path is meaningful wherever it is recorded.
# The wrappers also carry the TARGET PREFIX search paths. That is what keeps
# the sysroot out of the build's own vocabulary: because -isystem and -L are
# baked into argv[0] rather than passed through CFLAGS/LDFLAGS, the sysroot
# path never reaches a configure line, a recorded CFLAGS string, a generated
# .pc file, or libtool -- which hardcodes a RUNPATH for any -L directory it
# does not recognise as a system directory, and was stamping
# $SYSROOT/usr/lib into sudo's and libidn2's shared libraries.
#
# They come before "$@", so they win over the host's own /usr/local/include
# that USES=localbase appends.
CROSS_BINDIR=/usr/local/bin
for _pair in "cc:cc" "c++:c++" "cpp:cpp"; do
    _name="${_pair%%:*}"
    _base="${_pair#*:}"
    sudo sh -c "cat > ${CROSS_BINDIR}/${TRIPLE}-${_name}" <<EOF
#!/bin/sh
# -L is withheld from compile-only invocations. clang reports an unused -L as
# -Wunused-command-line-argument, and meson promotes exactly that to an error
# in every compiler probe it runs, so passing -L unconditionally made all of
# them fail -- including "supports function attribute visibility", which then
# left dns/libpsl's symbols unexported and its own tool unable to link.
# -isystem needs no such guard: clang does not warn about it when only linking.
for _a in "\$@"; do
    case "\$_a" in
        -c|-S|-E)
            exec /usr/bin/${_base} -target ${TRIPLE} --sysroot=${SYSROOT} \\
                -isystem ${TARGET_LOCALBASE}/include "\$@" ;;
    esac
done
exec /usr/bin/${_base} -target ${TRIPLE} --sysroot=${SYSROOT} \\
    -isystem ${TARGET_LOCALBASE}/include \\
    -L${TARGET_LOCALBASE}/lib \\
    -L${SYSROOT}/usr/lib "\$@"
EOF
    sudo chmod 755 "${CROSS_BINDIR}/${TRIPLE}-${_name}"
done
cat "${CROSS_BINDIR}/${TRIPLE}-cc"
"${CROSS_BINDIR}/${TRIPLE}-cc" --version | head -n 1

# LOCALBASE stays /usr/local (see the header), so the toolchain file that
# bsd.port.mk includes as ${LOCALBASE}/share/toolchains/<name>.mk belongs in
# the HOST prefix -- which is also where devel/freebsd-gcc13 would install it.
sudo mkdir -p /usr/local/share/toolchains
sudo sh -c "cat > /usr/local/share/toolchains/${CROSS_TOOLCHAIN}.mk" <<EOF
XCC=${CROSS_BINDIR}/${TRIPLE}-cc
XCXX=${CROSS_BINDIR}/${TRIPLE}-c++
XCPP=${CROSS_BINDIR}/${TRIPLE}-cpp
CROSS_BINUTILS_PREFIX=/usr/bin/
X_COMPILER_TYPE=clang
EOF
cat "/usr/local/share/toolchains/${CROSS_TOOLCHAIN}.mk"

# --- 3. Ports tree ----------------------------------------------------------
# Pinned to a quarterly branch for reproducibility, and fetched as a tarball
# with base fetch(1) rather than cloned, so no git needs installing.
if [ ! -f "$PORTSDIR/Mk/bsd.port.mk" ]; then
    echo "===== FETCHING PORTS TREE ($PORTS_BRANCH) ====="
    cd "$HOME"
    fetch_retry ports.tar.gz \
        "https://codeload.github.com/freebsd/freebsd-ports/tar.gz/refs/heads/${PORTS_BRANCH}"
    tar -xf ports.tar.gz
    mv "freebsd-ports-${PORTS_BRANCH}" "$PORTSDIR"
    rm -f ports.tar.gz
fi
[ -f "$PORTSDIR/Mk/bsd.port.mk" ] ||
    { echo "FATAL: no ports tree at $PORTSDIR" >&2; exit 1; }

# --- 4. The cross make arguments --------------------------------------------
# Passed on every ports make command line.
#
# LOCALBASE is deliberately NOT set here -- see the header. It stays /usr/local,
# which is simultaneously where the host's build tools live and where the
# target's own prefix lives at runtime, so every use of it is correct without
# any intervention. The target prefix reaches the compiler through the wrappers
# instead.
#
# PKG_CONFIG_LIBDIR is the exception that does have to be redirected: pkgconf
# would otherwise read the HOST prefix's .pc files and report amd64 libraries.
# bsd.port.mk already sets PKG_CONFIG_SYSROOT_DIR, which prefixes the paths
# those files name.
#
# AS needs the override. bsd.port.mk derives the whole binutils set uniformly
# as ${CROSS_BINUTILS_PREFIX}${tool} -- fine for ar/ld/nm/objcopy/ranlib/size/
# strings/strip, which base does ship as multi-target LLVM tools, but FreeBSD
# dropped GNU as from base back in 13, so /usr/bin/as does not exist at all.
# Point AS at the compiler driver instead, which assembles .s through clang's
# integrated assembler. It is set on the command line rather than in the
# toolchain .mk because bsd.port.mk's `.for _tool in AS AR LD ...` loop runs
# after the .mk is included and would overwrite it.
CROSS_ARGS="PORTSDIR=$PORTSDIR \
CROSS_TOOLCHAIN=$CROSS_TOOLCHAIN \
CROSS_SYSROOT=$SYSROOT \
PACKAGES=$PACKAGES \
BATCH=yes"
CROSS_ARGS="$CROSS_ARGS \
PKG_CONFIG_LIBDIR=$TARGET_LOCALBASE/libdata/pkgconfig:$SYSROOT/usr/libdata/pkgconfig"
# Kept out of CROSS_ARGS because its value contains spaces: CROSS_ARGS is
# deliberately word-split onto the make command line, so this one has to be
# passed as a single quoted argument instead.
CROSS_AS="AS=$CROSS_BINDIR/$TRIPLE-cc -c"

# bsd.port.mk builds CC as `${XCC} --sysroot=${CROSS_SYSROOT}`, which reasserts
# the arguments-in-a-compiler-variable problem the wrappers exist to avoid. The
# wrappers already carry -target and --sysroot, so pin the compiler variables
# to them directly; a command-line assignment wins over the makefile's.
#
# HOSTCC/HOSTCXX must be pinned in the same breath. bsd.port.mk seeds them from
# CC (`.if !defined(HOSTCC)` / `HOSTCC:= ${CC}`) before it reassigns CC to the
# cross compiler, so overriding CC without them would make the *native* build
# compiler -- the one CC_FOR_BUILD hands to configure for host-side codegen
# tools -- point at the cross compiler.
CROSS_COMPILER_ARGS="CC=$CROSS_BINDIR/$TRIPLE-cc \
CXX=$CROSS_BINDIR/$TRIPLE-c++ \
CPP=$CROSS_BINDIR/$TRIPLE-cpp \
HOSTCC=/usr/bin/cc \
HOSTCXX=/usr/bin/c++"
CROSS_ARGS="$CROSS_ARGS $CROSS_COMPILER_ARGS"

# Mk/Uses/ssl.mk hardcodes OPENSSLBASE=/usr for base OpenSSL, and OPENSSLINC /
# OPENSSLLIB follow from it. Those absolute paths are NOT sysroot-relative, so
# a port using base OpenSSL (ftp/curl) is handed -I/usr/include -L/usr/lib and
# links the build host's amd64 base libraries -- "C compiler cannot create
# executables". Point them into the sysroot. ssl.mk assigns them with `=`, so
# this has to be a command-line override rather than a make.conf default.
#
# Only OPENSSLINC is redirected, and only because it becomes a -I flag: -I
# outranks the sysroot's own include path, so leaving it at /usr/include would
# have ftp/curl compile against the build host's amd64 base headers.
#
# OPENSSLBASE and OPENSSLLIB are deliberately left at /usr. OPENSSLBASE is what
# ports pass to configure, and security/sudo records its configure line inside
# the sudo binary for `sudo -V`, so redirecting it wrote the sysroot into a
# shipped binary. OPENSSLLIB becomes -L, and libtool hardcodes a RUNPATH for
# any -L directory it does not recognise as a system one -- that is what put
# $SYSROOT/usr/lib into libsudo_util.so. The wrapper carries -L$SYSROOT/usr/lib
# instead, where it still precedes the port's own -L/usr/lib on the link line
# but is invisible to libtool.
CROSS_ARGS="$CROSS_ARGS OPENSSLINC=$SYSROOT/usr/include"

# Make bsd.port.mk include Mk/bsd.local.mk (written below).
CROSS_ARGS="$CROSS_ARGS USE_LOCAL_MK=yes"

# --- 4.5 Cross configuration for cmake and meson ----------------------------
# Neither Mk/Uses/cmake.mk nor Mk/Uses/meson.mk has ANY cross support, so both
# build systems probe the build host: cmake's find_package picked up the host's
# amd64 /usr/lib/libz.so for security/libssh2 ("incompatible with
# $SYSROOT/usr/lib/crti.o"), and meson tried to execute the target binary from
# its own compiler sanity check for dns/libpsl.
#
# Both take their settings through variables the framework accumulates with
# `+=` (CMAKE_ARGS, MESON_ARGS), which a command-line assignment would REPLACE
# rather than extend -- and cmake.mk invokes cmake under `env -i` (SETENVI), so
# an exported CMAKE_TOOLCHAIN_FILE would not survive either.
#
# /etc/make.conf is read BEFORE the port's own Makefile, which is too early to
# be useful: dns/libpsl opens with `MESON_ARGS= --default-library=both` and
# security/sudo with `CONFIGURE_ARGS= --mandir=...`, and a plain `=` discards
# whatever make.conf appended. (archivers/liblz4 was fixed from make.conf only
# because ALL_TARGET is a hard assignment there, which hid the problem.)
#
# Mk/bsd.local.mk is the hook that runs late: bsd.port.mk `.sinclude`s it under
# USE_LOCAL_MK, and the inclusion guarded by _POSTMKINCLUDED happens after the
# port Makefile has been read, so an append there survives.
echo "===== WRITING Mk/bsd.local.mk ====="
MESON_CROSS_FILE="$HOME/meson-cross-$TARGET_ARCH.ini"
cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$CROSS_BINDIR/$TRIPLE-cc'
cpp = '$CROSS_BINDIR/$TRIPLE-c++'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/usr/local/bin/pkgconf'

[properties]
# Without this meson still runs its compiler sanity-check binary and dies with
# "binary or interpreter not executable" -- it only infers that it cannot
# execute target binaries in some configurations, and a FreeBSD host building
# for another FreeBSD architecture is not one of them.
needs_exe_wrapper = true
sys_root = '$SYSROOT'
pkg_config_libdir = ['$TARGET_LOCALBASE/libdata/pkgconfig', '$SYSROOT/usr/libdata/pkgconfig']

[host_machine]
system = 'freebsd'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$TARGET_ARCH'
endian = '$MESON_ENDIAN'
EOF
cat "$MESON_CROSS_FILE"

# CMAKE_FIND_ROOT_PATH is deliberately a single path with no ';' -- cmake.mk
# expands CMAKE_ARGS through a shell, where a semicolon would end the command.
# One root is enough: the target prefix lives inside the sysroot, and FreeBSD's
# cmake already has /usr/local in CMAKE_SYSTEM_PREFIX_PATH.
cat > "$PORTSDIR/Mk/bsd.local.mk" <<EOF
# Written by scripts/cross-build.sh -- cross-compilation settings that have to
# be APPENDED to framework variables, which a make command line cannot do.
#
# Guarded on _POSTMKINCLUDED so this applies at the LATE inclusion only: the
# earlier one runs before the port Makefile, where a port's own \`MESON_ARGS=\`
# or \`CONFIGURE_ARGS=\` would discard everything appended here.
.if defined(_POSTMKINCLUDED) && !defined(_CROSS_LOCAL_MK)
_CROSS_LOCAL_MK=	yes

CMAKE_ARGS+=	-DCMAKE_SYSTEM_NAME=FreeBSD
CMAKE_ARGS+=	-DCMAKE_SYSTEM_PROCESSOR=${TARGET_ARCH}
CMAKE_ARGS+=	-DCMAKE_SYSROOT=${SYSROOT}
CMAKE_ARGS+=	-DCMAKE_FIND_ROOT_PATH=${SYSROOT}
CMAKE_ARGS+=	-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
CMAKE_ARGS+=	-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
CMAKE_ARGS+=	-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
CMAKE_ARGS+=	-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY

MESON_ARGS+=	--cross-file=${MESON_CROSS_FILE}

# Defence in depth for the RUNPATH libsudo_util.so kept acquiring. The actual
# cause turned out to be libtool hardcoding the -L${SYSROOT}/usr/lib that
# OPENSSLLIB used to add -- fixed by carrying that -L inside the compiler
# wrapper, where libtool cannot see it. sudo's configure has its own -R logic
# on top, and --disable-rpath is its documented off switch.
.if \${.CURDIR:M*/security/sudo}
CONFIGURE_ARGS+=	--disable-rpath
.endif

# archivers/liblz4's default target builds an HTML manual by compiling
# contrib/gen_manual FOR THE TARGET and then executing it on the build host,
# which cannot work when cross-compiling. Upstream's "allmost" target is
# precisely "all but the manuals" (all: allmost examples manuals build_tests),
# so it yields the library and the lz4 CLI without the unrunnable step.
.if \${.CURDIR:M*/archivers/liblz4}
ALL_TARGET=	allmost
.endif

.endif
EOF
cat "$PORTSDIR/Mk/bsd.local.mk"

# port_dir ORIGIN -> the port's directory, with any @flavor suffix stripped
port_dir() { echo "$PORTSDIR/${1%@*}"; }

# flavor_arg ORIGIN -> "FLAVOR=x" when the origin carries one, else nothing
flavor_arg() {
    case "$1" in
        *@*) echo "FLAVOR=${1#*@}" ;;
        *)   echo "" ;;
    esac
}

# cross_make ORIGIN ARGS... -- make for a port in the cross configuration.
# $CROSS_ARGS and flavor_arg are left unquoted on purpose: both are lists of
# whole make arguments and must word-split.
cross_make() {
    _o="$1"; shift
    ( cd "$(port_dir "$_o")" &&
      make $CROSS_ARGS "$CROSS_AS" $(flavor_arg "$_o") "$@" )
}

# host_make ORIGIN ARGS... -- make for a port in the plain NATIVE
# configuration. Used only to resolve a host build tool to its package name.
host_make() {
    _o="$1"; shift
    ( cd "$(port_dir "$_o")" &&
      make PORTSDIR="$PORTSDIR" BATCH=yes $(flavor_arg "$_o") "$@" )
}

# --- 5. Early assertion: the cross configuration resolves -------------------
# Seconds, not minutes: a mis-wired CROSS_* or a toolchain file in the wrong
# place fails here instead of after a full build. Every value asserted names
# the TARGET, never the amd64 build host.
echo "===== CROSS-CONFIG RESOLUTION ====="
_probe="$(grep -v '^[[:space:]]*#' "$PKGLIST" | grep -v '^[[:space:]]*$' | head -n 1)"
assert_var() {  # $1=VARNAME  $2=expected substring
    _v="$(cross_make "$_probe" -V "$1")"
    echo "$1 = [$_v]"
    case "$_v" in
        *"$2"*) : ;;
        *) echo "FATAL: $1 resolved to [$_v], expected to contain [$2]" >&2
           exit 1 ;;
    esac
}
assert_var ARCH "$TARGET_ARCH"
assert_var CC "$TRIPLE-cc"
assert_var HOSTCC /usr/bin/cc
assert_var CROSS_HOST "$TRIPLE"
# LOCALBASE must NOT have moved into the sysroot -- see the header. Assert it,
# because that mistake is silent: the build succeeds and the breakage only
# shows up as a build-machine path compiled into a shipped binary.
assert_var LOCALBASE /usr/local
assert_var PREFIX /usr/local
assert_var PKG_BIN /usr/local/sbin/pkg-static
# pkgconf, on the other hand, must read the TARGET prefix's .pc files.
assert_var PKG_CONFIG_LIBDIR "$TARGET_LOCALBASE/libdata/pkgconfig"
# Mk/bsd.local.mk must actually be reaching the ports. This failed silently
# once already -- the same settings in /etc/make.conf were read too early and
# discarded by ports that assign MESON_ARGS/CONFIGURE_ARGS with a plain `=`,
# and the only symptom was meson reporting "Build type: native build" deep in
# one port's log.
assert_var CMAKE_ARGS -DCMAKE_SYSTEM_NAME=FreeBSD
assert_var MESON_ARGS --cross-file=

# OSVERSION must come from the sysroot's sys/param.h and not from the build
# host: it decides version-conditional patches and is what pkg records. Compare
# against the value read straight out of the sysroot header.
_want_osversion="$(awk '/^#define[[:blank:]]+__FreeBSD_version/ {print $3}' \
    "$SYSROOT/usr/include/sys/param.h")"
assert_var OSVERSION "$_want_osversion"

# Every tool bsd.port.mk derives from CROSS_BINUTILS_PREFIX must actually
# exist. Base's copies are the multi-target LLVM ones so they need no target
# prefix, but a missing one would otherwise surface as a baffling failure deep
# inside some port's link step. (AS is excluded -- see the CROSS_AS note above;
# it is overridden to the compiler driver precisely because base has no `as`.)
for _tool in ar ld nm objcopy ranlib size strings strip; do
    [ -x "/usr/bin/$_tool" ] ||
        { echo "FATAL: /usr/bin/$_tool is missing from the build host" >&2
          exit 1; }
done

# The assertions above only prove the variables SAY the right thing. Actually
# compile and link something and look at what came out -- it is a couple of
# seconds, and it is the difference between "configured for the target" and
# "produces target binaries".
echo "===== TOOLCHAIN SMOKE TEST ====="
_probe_dir="$(mktemp -d -t xbuild-probe)"
echo 'int main(void) { return 0; }' > "$_probe_dir/t.c"
"$CROSS_BINDIR/$TRIPLE-cc" -o "$_probe_dir/t" "$_probe_dir/t.c"
_probe_machine="$(readelf -h "$_probe_dir/t" | sed -n 's/^ *Machine: *//p')"
echo "linked a test binary for: $_probe_machine"
case "$_probe_machine" in
    *"$ELF_MACHINE"*) : ;;
    *) echo "FATAL: the cross toolchain produced a [$_probe_machine] binary," \
            "expected [$ELF_MACHINE]" >&2; exit 1 ;;
esac
rm -rf "$_probe_dir"
echo "cross-config OK (OSVERSION $_want_osversion, read from the sysroot)"

# --- 6. Classify and order the dependency closure ---------------------------
# The framework cannot tell a host tool from a target library, so do it here.
# At each port its DIRECT dependencies split by kind:
#
#   LIB_DEPENDS / RUN_DEPENDS   linked into or run on the TARGET -> cross-build
#   BUILD_ / EXTRACT_ /         executed on the build HOST       -> pkg install
#   PATCH_ / FETCH_DEPENDS
#
# Recursion only follows the target side: everything underneath a host tool is
# also a host tool, and `pkg install` resolves that closure for free.
#
# The lists are evaluated WITH the cross arguments, so options -- and therefore
# dependencies -- match what will actually be built.

# dep_origins ORIGIN VARNAME... -> the origins named by those dependency
# variables. Entries look like `libnghttp2.so:www/libnghttp2`,
# `pkgconf>=1.3:devel/pkgconf` or `/usr/local/bin/foo:x/y:extract`; the origin
# is always the second colon-separated field.
dep_origins() {
    _origin="$1"; shift
    for _var in "$@"; do
        cross_make "$_origin" -V "$_var"
    done | tr ' ' '\n' | awk -F: 'NF >= 2 && $2 != "" { print $2 }' | sort -u
}

target_deps() { dep_origins "$1" LIB_DEPENDS RUN_DEPENDS; }
host_deps() {
    dep_origins "$1" BUILD_DEPENDS EXTRACT_DEPENDS PATCH_DEPENDS FETCH_DEPENDS
}

# Post-order DFS over the target closure, so a port is always visited after
# everything it links against. The accumulators are globals deliberately --
# running visit() in a subshell would discard them -- while the per-frame
# variables must be `local` or the recursive calls would clobber them.
visited=""
build_order=""
host_tools=""

visit() {  # $1 = origin
    local origin dep deps
    origin="$1"
    case " $visited " in *" $origin "*) return 0 ;; esac
    visited="$visited $origin"

    if [ ! -d "$(port_dir "$origin")" ]; then
        echo "FATAL: no such port origin: $origin" >&2
        exit 1
    fi

    # Record this port's identity and its DIRECT target dependencies while we
    # are here. Both are needed in step 7 to write the manifest deps block, and
    # a make invocation per port is far cheaper than one per dependency edge.
    printf '%s\t%s\n' "$origin" \
        "$(cross_make "$origin" -V PKGBASE -V PKGORIGIN -V PKGVERSION |
           tr '\n' '\t')" >> "$METAFILE"

    deps="$(target_deps "$origin" | tr '\n' ' ')"
    printf '%s\t%s\n' "$origin" "$deps" >> "$MANIFEST_DEPS_DIR/edges"

    for dep in $deps; do
        visit "$dep"
    done
    host_tools="$host_tools $(host_deps "$origin" | tr '\n' ' ')"
    build_order="$build_order $origin"
}

echo "===== RESOLVING DEPENDENCY CLOSURE ====="
rm -rf "$MANIFEST_DEPS_DIR"
mkdir -p "$MANIFEST_DEPS_DIR"
: > "$METAFILE"
requested=""
while IFS= read -r origin || [ -n "$origin" ]; do
    case "$origin" in ''|\#*) continue ;; esac
    origin="$(printf '%s' "$origin" | tr -d '[:space:]')"
    [ -n "$origin" ] || continue
    requested="$requested $origin"
    visit "$origin"
done < "$PKGLIST"

# A port can legitimately appear in both lists -- gettext-runtime is a target
# library for bash and a host dependency of gettext-tools. Installing the amd64
# build of it alongside the cross-built one is harmless precisely because the
# two prefixes are separate: the host copy lands in /usr/local, where only
# host tools are looked up, and the target copy in $SYSROOT/usr/local, which
# only the compiler wrappers search.
host_tools="$(printf '%s\n' $host_tools | sort -u)"
echo "target build order:$build_order"
echo "host tools:"
printf '  %s\n' $host_tools

# --- 6.5 Install the host build tools ---------------------------------------
# Plain amd64 binary packages from the official mirror -- seconds, not a build.
# pkg resolves each one's own transitive closure.
if [ -n "$host_tools" ]; then
    echo "===== INSTALLING HOST BUILD TOOLS ====="
    for tool in $host_tools; do
        # `pkg install <category/port>` matches on origin, which is what we
        # have. A flavored origin has no unambiguous origin match, so fall back
        # to the port's own package name.
        if ! sudo pkg install -y "${tool%@*}"; then
            _name="$(host_make "$tool" -V PKGBASE)"
            echo "origin install failed for $tool, retrying as $_name" >&2
            sudo pkg install -y "$_name"
        fi
    done
fi

# USES=python makes the closure depend on a VERSIONED interpreter
# (lang/python312), which installs python3.12 but no bare `python3`. Ports that
# invoke the framework's PYTHON_CMD are fine, but a configure script looking
# for `python3` on PATH is not: net/rsync's aborts with "no - python3 not
# found". lang/python3 is the meta-port that provides the unversioned link.
if ! command -v python3 >/dev/null 2>&1; then
    echo "===== no python3 on PATH; installing lang/python3 ====="
    sudo pkg install -y lang/python3
fi
command -v python3 || echo "WARNING: still no python3 on PATH" >&2

# --- 7. Cross-build each port in order --------------------------------------
# NO_DEPENDS=yes: the closure was ordered in step 6, and the framework's own
# dependency checks cannot tell the two prefixes apart.
#
# After each build the package is unpacked into the sysroot so the next port
# finds its headers and libraries on the wrappers' search path. Unpacking the
# tarball
# directly rather than `pkg -r $SYSROOT add` avoids arguing pkg out of its ABI
# check for no benefit -- nothing here reads the target's package database.

# manifest_deps ORIGIN -> the dependency block for ORIGIN's package manifest,
# in the `"name": {origin: "o", version: "v"}` form create-manifest.sh expects
# from ACTUAL-PACKAGE-DEPENDS. Direct dependencies only; pkg walks the graph
# transitively from each package's own list.
# dump_config_logs ORIGIN -- surface a configure failure in this run's log. A
# cross-configure error ("cannot run C compiled programs", a missing target
# library) is otherwise invisible without another CI round trip.
dump_config_logs() {  # $1 = origin
    find "$(port_dir "$1")" -maxdepth 4 -name config.log 2>/dev/null |
    while IFS= read -r cl; do
        echo "----- config.log: $cl (error lines) -----"
        grep -nE "configure:[0-9]+:|error|cannot|conftest|clang|/ld|C compiler" \
            "$cl" 2>/dev/null | head -n 60 || true
        echo "----- config.log: $cl (last 25 lines) -----"
        tail -n 25 "$cl" 2>/dev/null || true
    done
    # meson keeps its own log, and it is the only place the failing probe's
    # actual compiler invocation and error appear -- the terminal output just
    # says "NO". Without this a meson cross failure needs another CI round trip
    # to diagnose.
    find "$(port_dir "$1")" -maxdepth 6 -name meson-log.txt 2>/dev/null |
    while IFS= read -r ml; do
        echo "----- meson-log: $ml (failed checks) -----"
        grep -nE -A12 "Running compile:|Code:|Compiler stderr:" "$ml" 2>/dev/null |
            head -n 120 || true
    done
}

# normalise_sysroot DIR -- strip the sysroot prefix from every TEXT file under
# DIR, turning a build-time path into the target's own. grep -I skips binaries,
# which must never be rewritten; sed -i needs an (empty) backup suffix on BSD.
normalise_sysroot() {  # $1 = directory
    [ -d "$1" ] || return 0
    grep -Ilr "$SYSROOT" "$1" 2>/dev/null |
    while IFS= read -r f; do
        echo "  normalising sysroot path in ${f#$1}"
        sed -i '' -e "s|$SYSROOT||g" "$f"
    done
}

manifest_deps() {  # $1 = origin
    local origin dep
    origin="$1"
    for dep in $(awk -F'\t' -v o="$origin" '$1 == o { print $2 }' \
                     "$MANIFEST_DEPS_DIR/edges"); do
        awk -F'\t' -v d="$dep" '$1 == d {
            printf "\"%s\": {origin: \"%s\", version: \"%s\"}\n", $2, $3, $4
        }' "$METAFILE"
    done
}

mkdir -p "$PACKAGES/All"
failed=""
built_pkgfiles=""

for origin in $build_order; do
    echo "===== CROSS-BUILDING $origin ====="

    # See the header: without this the manifest would claim the package has no
    # dependencies, because the framework probes the host pkg database for
    # libraries that only exist in the sysroot.
    depfile="$MANIFEST_DEPS_DIR/$(printf '%s' "$origin" | tr '/@' '__')"
    manifest_deps "$origin" > "$depfile"
    echo "manifest deps for $origin:"
    cat "$depfile"

    # Stage and package are run as separate steps so the staged tree can be
    # rewritten in between -- see normalise_sysroot below.
    if ! cross_make "$origin" stage NO_DEPENDS=yes \
            "ACTUAL-PACKAGE-DEPENDS=cat $depfile"; then
        echo "CROSS BUILD FAILED: $origin" >&2
        failed="$failed $origin"
        dump_config_logs "$origin"
        continue
    fi

    # Translate build-time sysroot paths into the paths they will have on the
    # target. A cross build cannot avoid recording some of these: pointing
    # OPENSSLINC/OPENSSLLIB into the sysroot is what stops ftp/curl compiling
    # against the host's amd64 base headers, and cmake then writes the
    # directory it found OpenSSL in straight into libssh2.pc as
    # `Libs.private: -L$SYSROOT/usr/lib`.
    #
    # Stripping the prefix is the correct translation, not a cover-up:
    # $SYSROOT/usr IS /usr on the target. This is the same rewrite every
    # cross-build system performs on staged metadata. It is deliberately
    # limited to TEXT files (grep -I skips binaries) -- a sysroot path inside
    # an ELF file is a RUNPATH or a compiled-in constant, which cannot be
    # safely rewritten and must fail the build instead. The check below still
    # enforces that.
    normalise_sysroot "$(cross_make "$origin" -V STAGEDIR)"

    if ! cross_make "$origin" package NO_DEPENDS=yes \
            "ACTUAL-PACKAGE-DEPENDS=cat $depfile"; then
        echo "CROSS PACKAGE FAILED: $origin" >&2
        failed="$failed $origin(package)"
        dump_config_logs "$origin"
        continue
    fi

    pkgfile="$(cross_make "$origin" -V PKGFILE)"
    if [ ! -f "$pkgfile" ]; then
        echo "FATAL: $origin reported PKGFILE=$pkgfile but it does not exist" >&2
        failed="$failed $origin(no-pkgfile)"
        continue
    fi

    # Unpack somewhere private first, so the package can be inspected before it
    # is allowed anywhere near the sysroot.
    staged="$(mktemp -d -t xbuild)"
    tar -xf "$pkgfile" -C "$staged" --exclude '+*'

    # Text metadata was already translated in the staging dir, so anything
    # still naming the sysroot here is inside a binary: a RUNPATH, or a path
    # compiled in as a constant. Neither can be rewritten safely and both are
    # broken on the target, so fail rather than publish.
    if grep -rl "$SYSROOT" "$staged" 2>/dev/null | grep -q .; then
        echo "FATAL: $origin leaked the sysroot path into its package:" >&2
        # Say HOW it leaked, not just that it did. A path recorded in an ELF
        # RUNPATH is a broken library search at runtime and has to be fixed at
        # link time; the same path sitting in a .pc file or a recorded CFLAGS
        # string is a text substitution. The two need different fixes, and
        # without this the log cannot tell them apart.
        grep -rl "$SYSROOT" "$staged" 2>/dev/null |
        while IFS= read -r bad; do
            echo "  --- ${bad#$staged} ---" >&2
            if head -c 4 "$bad" 2>/dev/null | grep -q 'ELF'; then
                readelf -d "$bad" 2>/dev/null |
                    grep -E 'RPATH|RUNPATH' >&2 || echo "    (no RPATH/RUNPATH)" >&2
            fi
            strings -a "$bad" 2>/dev/null | grep -F "$SYSROOT" | head -n 3 |
                sed 's/^/    /' >&2 || true
        done
        failed="$failed $origin(sysroot-leak)"
        rm -rf "$staged"
        continue
    fi

    # Every ELF in the package must be for the target. The findings go to a
    # file because the `find | while` loop runs in a subshell.
    if [ -n "$ELF_MACHINE" ]; then
        wrong_list="$(mktemp -t xbuild-arch)"
        find "$staged" -type f -print |
        while IFS= read -r f; do
            head -c 4 "$f" 2>/dev/null | grep -q 'ELF' || continue
            m="$(readelf -h "$f" 2>/dev/null |
                 sed -n 's/^ *Machine: *//p')"
            [ -n "$m" ] || continue
            case "$m" in
                *"$ELF_MACHINE"*) : ;;
                *) echo "$f -> $m" >> "$wrong_list" ;;
            esac
        done
        if [ -s "$wrong_list" ]; then
            echo "FATAL: $origin produced binaries that are not $ELF_MACHINE:" >&2
            cat "$wrong_list" >&2
            failed="$failed $origin(wrong-arch)"
            rm -f "$wrong_list"
            rm -rf "$staged"
            continue
        fi
        rm -f "$wrong_list"
    fi

    # Populate the target prefix for the ports built after this one. tar rather
    # than cp -R so existing files and symlinks are overwritten cleanly, and
    # -m so it does not try to restore mtimes on the sysroot's own directories
    # (pointless here, and the first thing to fail on any dir we do not own).
    ( cd "$staged" && tar -cf - . ) | ( cd "$SYSROOT" && tar -xmf - )
    rm -rf "$staged"

    built_pkgfiles="$built_pkgfiles $pkgfile"
    echo "CROSS BUILD OK: $origin -> $(basename "$pkgfile")"

    # Free the work tree between ports to bound disk use.
    cross_make "$origin" clean NO_DEPENDS=yes >/dev/null 2>&1 || true
done

# --- 8. Assemble the pkg repository -----------------------------------------
# poudriere used to produce this layout; build it by hand now. `pkg repo` runs
# fine on the amd64 host over target packages -- it only reads their manifests.
echo "===== ASSEMBLING PKG REPOSITORY ====="
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR/All"
for f in $built_pkgfiles; do
    cp "$f" "$PUBLISH_DIR/All/"
done

# Every package must carry the target ABI, or a client will refuse it.
for f in "$PUBLISH_DIR"/All/*.pkg; do
    [ -f "$f" ] || continue
    abi="$(pkg info -F "$f" 2>/dev/null |
           sed -n 's/^Architecture[[:space:]]*:[[:space:]]*//p')"
    echo "  $(basename "$f") ($abi)"
    case "$abi" in
        "$TARGET_ABI"|"$NOARCH_ABI"|'*') : ;;
        *) echo "FATAL: $(basename "$f") has ABI [$abi], expected [$TARGET_ABI]" >&2
           failed="$failed $(basename "$f")(wrong-abi)" ;;
    esac
done

# `pkg bootstrap` on the target fetches Latest/pkg.pkg, so publish it whenever
# the pkg port is part of the set.
latest_pkg="$(ls "$PUBLISH_DIR"/All/pkg-[0-9]*.pkg 2>/dev/null | head -n 1 || true)"
if [ -n "$latest_pkg" ]; then
    mkdir -p "$PUBLISH_DIR/Latest"
    cp "$latest_pkg" "$PUBLISH_DIR/Latest/pkg.pkg"
fi

pkg repo "$PUBLISH_DIR"

# Every requested origin must be present in the published set.
for origin in $requested; do
    want="$(cross_make "$origin" -V PKGNAME 2>/dev/null || true)"
    if [ -n "$want" ] && [ -f "$PUBLISH_DIR/All/$want.pkg" ]; then
        echo "requested package OK: $want.pkg"
    else
        echo "FATAL: requested origin $origin produced no package (${want:-?})" >&2
        case "$failed" in
            *"$origin"*) : ;;
            *) failed="$failed $origin(missing)" ;;
        esac
    fi
done

# --- 9. Hand the repository back to the runner ------------------------------
# Only WORKSPACE is synced back; everything above lives in $HOME.
OUT="$WORKSPACE/packages"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$PUBLISH_DIR"/. "$OUT/"
ls -lR "$OUT"

if [ -n "$failed" ]; then
    echo "===== FAILED:$failed =====" >&2
    exit 1
fi
echo "===== OK: every requested origin cross-built for $TARGET_ABI ====="
