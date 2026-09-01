#!/bin/sh
# Diagnostic dump for QEMU user-mode emulation failures. Runs after the
# poudriere jail base is unpacked but before `poudriere bulk`, so the
# target-arch binaries are available on disk for inspection.
#
# Required environment variables:
#   BINMISCCTL_NAME - e.g. powerpc64
#   QEMU_BINARY     - e.g. qemu-ppc64-static
#   JAIL_NAME       - e.g. powerpc64-150
#
# Optional:
#   QEMU_ARGS       - e.g. "-cpu power9"

# Intentionally no `set -e`: we want every probe to run even if one fails.
: "${QEMU_ARGS:=}"

JAIL_DIR="/usr/local/poudriere/jails/${JAIL_NAME}"
TARGET_BIN="${JAIL_DIR}/usr/bin/id"
QEMU="/usr/local/bin/${QEMU_BINARY}"

echo "==== binmiscctl list ===="
binmiscctl list
echo

echo "==== binmiscctl lookup ${BINMISCCTL_NAME} ===="
binmiscctl lookup "${BINMISCCTL_NAME}"
echo

echo "==== qemu-user-static package contents (ppc/powerpc) ===="
pkg info -l qemu-user-static 2>/dev/null | grep -Ei 'ppc|powerpc'
echo

echo "==== ${QEMU} ===="
ls -l "${QEMU}"
file "${QEMU}"
echo

echo "==== ${QEMU} --version ===="
# shellcheck disable=SC2086
"${QEMU}" ${QEMU_ARGS} --version
echo

echo "==== file ${TARGET_BIN} ===="
file "${TARGET_BIN}"
echo

echo "==== first 64 bytes of ${TARGET_BIN} ===="
hexdump -C -n 64 "${TARGET_BIN}"
echo

echo "==== TEST A: direct qemu, no -L (expected to fail: host ld-elf is amd64) ===="
# shellcheck disable=SC2086
"${QEMU}" ${QEMU_ARGS} "${TARGET_BIN}"
echo "exit: $?"
echo

echo "==== TEST B: direct qemu, -L ${JAIL_DIR} (qemu resolves libs in jail) ===="
# shellcheck disable=SC2086
"${QEMU}" ${QEMU_ARGS} -L "${JAIL_DIR}" "${TARGET_BIN}"
echo "exit: $?"
echo

echo "==== TEST C: chroot + manual qemu invocation (mirrors binmiscctl path) ===="
# Copy qemu into the jail tree so it's reachable post-chroot, then run
# it explicitly (not via binmiscctl) inside the chroot. If this works
# but TEST D fails, the bug is in the binmiscctl path. If this fails
# too, qemu itself can't run dyn-linked FreeBSD/PPC64 binaries.
cp "${QEMU}" "${JAIL_DIR}/usr/local/bin/${QEMU_BINARY}" 2>/dev/null || \
    { mkdir -p "${JAIL_DIR}/usr/local/bin" && cp "${QEMU}" "${JAIL_DIR}/usr/local/bin/${QEMU_BINARY}"; }
# shellcheck disable=SC2086
chroot "${JAIL_DIR}" "/usr/local/bin/${QEMU_BINARY}" ${QEMU_ARGS} /usr/bin/id
echo "exit: $?"
echo

echo "==== TEST D: chroot + implicit binmiscctl dispatch ===="
chroot "${JAIL_DIR}" /usr/bin/id
echo "exit: $?"
