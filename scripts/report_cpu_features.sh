#!/bin/bash
#-------------------------------------------------------------------------------
# report_cpu_features [executable]
#
#  (1) always: report this host's CPU and its microarchitecture (SIMD) features.
#  (2) optional: given an executable, also report the ISA it REQUIRES, so a
#      binary built for a newer CPU than the host (a latent SIGILL, e.g. an
#      nvhpc binary targeting -tp znver4/AVX-512 run on an AVX2-only runner)
#      is obvious instead of a bare "Illegal instruction".
#
#  Installed as /container/bin/report_cpu_features by the final stage of
#  containers/devenv/Dockerfile.  It lives here, not in a base_os heredoc, so a
#  change to it rebuilds the final stage only.
#
#  Lines that other tools read -- part of the base contract (CONTRACT.md):
#
#    "  ISA flags: ..."                       x86_64 host
#    "  SIMD: ..."                            aarch64 host
#    "  AVX-512 (zmm) used by binary: YES|no" any %zmm register, anywhere
#    "  AVX-512 required: YES|no ..."         %zmm outside run-time-dispatched
#                                             routines -- the line that says
#                                             whether the binary can SIGILL
#    (and the same two for SVE on aarch64)
#
#  "Used" is not "required".  A oneAPI binary names %zmm whenever it links
#  Intel's SVML, whose __svml_*_z0 routines are chosen from CPUID when the
#  program starts and never run on a host without AVX-512.  So the wide
#  registers are reported by FUNCTION, and functions known to be dispatched are
#  set apart.  A stripped binary has no function names; its wide instructions
#  are then counted against the section, which is treated as required.
#
#  Works on x86_64 and aarch64; purely informational, never fails the caller.
#-------------------------------------------------------------------------------
arch=$(uname -m)

echo "== host: $(uname -mns) =="
case "${arch}" in
    x86_64)
        grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'
        echo -n "  ISA flags: "
        grep -m1 flags /proc/cpuinfo | grep -oE 'avx512[a-z]*|avx2|fma|bmi[12]|sse4_[12]' | sort -u | tr '\n' ' '
        echo
        ;;
    aarch64|arm64)
        grep -m1 -E 'CPU implementer|CPU part' /proc/cpuinfo
        echo -n "  SIMD: "
        grep -m1 'Features' /proc/cpuinfo | grep -oE 'asimd|sve[0-9]*|fphp|bf16|i8mm' | sort -u | tr '\n' ' '
        echo
        ;;
    *)
        echo "  (unhandled arch ${arch})"
        ;;
esac

bin="${1:-}"
[[ -z "${bin}" ]] && exit 0
if [[ ! -e "${bin}" ]]; then
    echo "report_cpu_features: no such file: ${bin}" >&2
    exit 0
fi

echo "== ${bin} requires =="
command -v ldd >/dev/null 2>&1 && { ldd "${bin}" 2>/dev/null || true; }
if command -v readelf >/dev/null 2>&1; then
    notes="$(readelf -nW "${bin}" 2>/dev/null | grep -iE 'ISA|feature|properties')"
    if [[ -n "${notes}" ]]; then
        echo "${notes}"
        if grep -q 'ISA needed' <<< "${notes}"; then
            echo "  (\"ISA needed\" is meaningful only for a binary built with gcc -mneeded;"
            echo "   otherwise gcc records x86-64-baseline whatever -march said.  The"
            echo "   AVX-512 lines below, or a count of %ymm/vfmadd in objdump -d, are"
            echo "   what the binary actually uses.)"
        fi
    else
        echo "  (no GNU ISA-needed note)"
    fi
fi

# Routines that carry a wide copy beside narrower ones and pick one from CPUID:
# Intel's SVML (_z0 = AVX-512), libm and memcpy family, and OpenBLAS's
# DYNAMIC_ARCH kernels, which carry the core they were built for as a suffix.
dispatched () {
    case "$1" in
        __svml_*|__intel_*|_intel_fast_*|__libm_*) return 0 ;;
        *_SKYLAKEX|*_COOPERLAKE|*_SAPPHIRERAPIDS) return 0 ;;
        *_A64FX|*_NEOVERSEV1|*_NEOVERSEV2|*_ARMV8SVE) return 0 ;;
    esac
    return 1
}

command -v objdump >/dev/null 2>&1 || { echo "  (no objdump: wide-register use unchecked)"; exit 0; }

case "${arch}" in
    x86_64)        wide="AVX-512"; regs='%zmm[0-9]+';        what="zmm";    host_needs="an AVX-512" ;;
    aarch64|arm64) wide="SVE";     regs='z[0-9]+\.[bhsd]';  what="z-regs"; host_needs="an SVE" ;;
    *)             exit 0 ;;
esac

# "<count> <function>" for every function with a wide instruction in it.
by_fn="$(objdump -d --no-show-raw-insn "${bin}" 2>/dev/null \
    | awk -v re="${regs}" '/^[0-9a-f]+ <.*>:$/ { f = $2; gsub(/[<>:]/, "", f) }
                           $0 ~ re { n[f]++ }
                           END { for (k in n) print n[k], k }' \
    | sort -k2)"

if [[ -z "${by_fn}" ]]; then
    echo "  ${wide} (${what}) used by binary: no"
    echo "  ${wide} required: no"
    exit 0
fi

echo "  ${wide} (${what}) used by binary: YES"
echo "  ${wide} by function (instructions, function, kind):"
own=0
while read -r count fn; do
    if dispatched "${fn}"; then
        kind="run-time dispatched"
    else
        kind="own"
        own=$((own + 1))
    fi
    printf '    %6d  %s  [%s]\n' "${count}" "${fn}" "${kind}"
done <<< "${by_fn}"

if [[ ${own} -gt 0 ]]; then
    echo "  ${wide} required: YES  (in ${own} of its own functions; requires ${host_needs} host)"
else
    echo "  ${wide} required: no  (only in run-time-dispatched routines, never run without ${wide})"
fi
exit 0
