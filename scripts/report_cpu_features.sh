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
#    "  AVX-512 required: YES|no ..."         any AVX-512 instruction -- %zmm or
#                                             EVEX on %xmm/%ymm (AVX-512VL) --
#                                             outside run-time-dispatched
#                                             routines: the line that says
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
# Intel's SVML (_z0 = AVX-512), libm and memcpy family; OpenBLAS's DYNAMIC_ARCH
# kernels, which carry the core they were built for as a suffix; and FFTW's
# SIMD codelets, which its planner offers only when the CPU has the ISA.  The
# last two matter when the "binary" is the base's own libopenblas or libfftw3.
dispatched () {
    case "$1" in
        __svml_*|__intel_*|_intel_fast_*|__libm_*) return 0 ;;
        *_SKYLAKEX|*_COOPERLAKE|*_SAPPHIRERAPIDS) return 0 ;;
        fftw*_avx512|fftw*_avx512_*) return 0 ;;
        *_A64FX|*_NEOVERSEV1|*_NEOVERSEV2|*_ARMV8SVE) return 0 ;;
    esac
    return 1
}

command -v objdump >/dev/null 2>&1 || { echo "  (no objdump: wide-register use unchecked)"; exit 0; }

# Two questions, asked of every instruction:
#
#   USED      names a full-width register (%zmm, SVE z) -- the contract's
#             "used by binary" line, unchanged.
#   REQUIRED  needs the ISA at all.  AVX-512 is not only %zmm: with AVX-512VL
#             an EVEX instruction can work on %xmm/%ymm, and gcc's own AVX-512
#             targets prefer 256-bit vectors, so a -march=icelake-server binary
#             can need AVX-512 without naming one %zmm.  EVEX is recognised by
#             what only it can express -- a %zmm, a mask register %k0-7,
#             %xmm/%ymm16-31, an embedded broadcast {1toN}, rounding {rn-sae},
#             zeroing {z} -- or by a mnemonic that exists only in AVX-512.  An
#             EVEX instruction on %xmm/%ymm0-15 with no mask, broadcast or
#             AVX-512-only mnemonic is not caught: "required: no" means none
#             of these was found, not a proof.
case "${arch}" in
    x86_64)
        wide="AVX-512"; what="zmm"; host_needs="an AVX-512"
        used_re='%zmm[0-9]'
        req_re='%zmm[0-9]|%k[0-7]|%[xy]mm(1[6-9]|2[0-9]|3[01])|[{]1to[0-9]+[}]|[{]r[nduz]-sae[}]|[{]sae[}]|[{]z[}]|[{]evex[}]'
        mn_re='^(vpternlog|vpermt2|vpermi2|vpro[lr]|vpmovu?s?(qb|qw|qd|db|dw|wb)[ x]|vpmov[bwdq]2m|vpmovm2|vcvtt?(pd|ps|sd|ss)2u|vcvtu|vcvtt?(pd|ps)2u?qq|vcvtu?qq2|vpcompress|vpexpand|vcompressp|vexpandp|vrndscale|vrange|vreduce|vgetexp|vgetmant|vscalef|vfixupimm|vpconflict|vplzcnt|valign[dq]|vpopcnt|vpshufbitqmb|vpmultishiftqb|vperm[bw] |vpsravw|vpsllvw|vpsrlvw|vdbpsadbw|vpmadd52|vpsh[lr]d|vpcmpu?[bwdq] |vptestn?m|vp?blendm|vfpclass|vrcp14|vrsqrt14|vextract[fi](32x4|32x8|64x2|64x4)|vinsert[fi](32x4|32x8|64x2|64x4)|vbroadcast[fi](32x2|32x4|32x8|64x2|64x4)|vshuf[fi](32x4|64x2)|vpbroadcastm|k(mov|and|andn|or|xor|xnor|not|shift[lr]|test|ortest|unpck|add)[bwdq])'
        ;;
    aarch64|arm64)
        wide="SVE"; what="z-regs"; host_needs="an SVE"
        used_re='z[0-9]+[.][bhsdq]'
        req_re='z[0-9]+[.][bhsdq]|[^a-z]p[0-9]+(/[mz]|[.][bhsd])'
        mn_re=''
        ;;
    *)  exit 0 ;;
esac

# "<required> <used> <function>" for every function needing the ISA.  The
# patterns go through the environment, not -v, so awk does not reinterpret
# their backslashes.
by_fn="$(objdump -d --no-show-raw-insn "${bin}" 2>/dev/null \
    | USED_RE="${used_re}" REQ_RE="${req_re}" MN_RE="${mn_re}" awk '
        BEGIN { used = ENVIRON["USED_RE"]; req = ENVIRON["REQ_RE"]; mn = ENVIRON["MN_RE"] }
        /^[0-9a-f]+ <.*>:$/ { f = $2; gsub(/[<>:]/, "", f); next }
        {
            t = index($0, "\t"); if (t == 0) next
            ins = substr($0, t + 1)
            if (ins ~ req || (mn != "" && ins ~ mn)) {
                r[f]++
                if (ins ~ used) u[f]++
            }
        }
        END { for (k in r) print r[k], u[k] + 0, k }' \
    | sort -k3)"

if [[ -z "${by_fn}" ]]; then
    echo "  ${wide} (${what}) used by binary: no"
    echo "  ${wide} required: no  (no ${wide} instruction found)"
    exit 0
fi

if awk '$2 > 0 { found = 1 } END { exit !found }' <<< "${by_fn}"; then
    echo "  ${wide} (${what}) used by binary: YES"
else
    echo "  ${wide} (${what}) used by binary: no  (but ${wide} instructions on narrower registers, below)"
fi
echo "  ${wide} by function (instructions, of them ${what}, function, kind):"
own=0
while read -r count nused fn; do
    if dispatched "${fn}"; then
        kind="run-time dispatched"
    else
        kind="own"
        own=$((own + 1))
    fi
    printf '    %6d %6d  %s  [%s]\n' "${count}" "${nused}" "${fn}" "${kind}"
done <<< "${by_fn}"

if [[ ${own} -gt 0 ]]; then
    echo "  ${wide} required: YES  (in ${own} of its own functions; requires ${host_needs} host)"
else
    echo "  ${wide} required: no  (only in run-time-dispatched routines, never run without ${wide})"
fi
exit 0
