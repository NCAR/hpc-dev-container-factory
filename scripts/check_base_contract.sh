#!/bin/bash
#-------------------------------------------------------------------------------
# check_base_contract.sh [--published]
#
# Checks that this image keeps the promises CONTRACT.md makes to anything built
# on it, and a few things the factory itself promises about its images.  Runs
# inside the image:
#
#     docker run --rm <image> /container/extras/check_base_contract.sh
#     apptainer exec <image>.sif /container/extras/check_base_contract.sh
#
# --published   also require what only the publish stage adds (OSU and its app
#               contract).  Without it, their absence is a SKIP.
#
# EXPECT_CONDA=true|false, if set, checks that Miniforge is present or absent.
#
# Prints one line per check, PASS / FAIL / SKIP / INFO, and exits non-zero if
# anything FAILed.
#-------------------------------------------------------------------------------
published=0
[ "${1:-}" = "--published" ] && published=1

[ -r /container/config_env.sh ] && source /container/config_env.sh

nfail=0
pass () { printf 'PASS  %s\n' "$*"; }
fail () { printf 'FAIL  %s\n' "$*"; nfail=$((nfail + 1)); }
skip () { printf 'SKIP  %s\n' "$*"; }
info () { printf 'INFO  %s\n' "$*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")" || { echo "cannot make a work directory"; exit 1; }
trap 'rm -rf "${work}"' EXIT
arch="$(uname -m)"

echo "== the base contract (CONTRACT.md) =="

# 1. config_env.sh
if [ -r /container/config_env.sh ]; then
    pass "/container/config_env.sh is present"
else
    fail "/container/config_env.sh is missing"
fi

# 2. build_common.cfg sets INSTALL_ROOT and STAGE_DIR
if [ -r /container/extras/build_common.cfg ]; then
    vals="$(unset INSTALL_ROOT STAGE_DIR; source /container/extras/build_common.cfg >/dev/null 2>&1
            echo "${INSTALL_ROOT:-}|${STAGE_DIR:-}")"
    if [ -n "${vals%%|*}" ] && [ -n "${vals##*|}" ]; then
        pass "build_common.cfg sets INSTALL_ROOT=${vals%%|*} STAGE_DIR=${vals##*|}"
    else
        fail "build_common.cfg does not set INSTALL_ROOT and STAGE_DIR (got '${vals}')"
    fi
else
    fail "/container/extras/build_common.cfg is missing"
fi

# 3. MARCH_FLAGS is declared, even when empty
if grep -q '^export MARCH_FLAGS=' /container/config_env.sh 2>/dev/null; then
    pass "MARCH_FLAGS is declared (\"${MARCH_FLAGS:-}\")"
else
    fail "MARCH_FLAGS is not exported by config_env.sh"
fi

# 4. CC, CXX, FC, and the MPI wrappers
for v in CC CXX FC; do
    val="${!v:-}"
    if [ -n "${val}" ] && command -v "${val%% *}" >/dev/null 2>&1; then
        pass "${v}=${val}"
    else
        fail "${v} is unset or not runnable ('${val}')"
    fi
done
for w in mpicc mpicxx mpifort; do
    if command -v "${w}" >/dev/null 2>&1; then
        pass "${w} -> $(command -v "${w}")"
    else
        fail "${w} is not on PATH"
    fi
done

# 5. report_placement and report_cpu_features
if [ -x /container/bin/report_placement ]; then
    pass "/container/bin/report_placement is installed"
else
    fail "/container/bin/report_placement is missing"
fi
if [ -x /container/bin/report_cpu_features ]; then
    probe="/container/bin/report_placement"
    [ -x "${probe}" ] || probe="$(command -v bash)"
    /container/bin/report_cpu_features "${probe}" > "${work}/rcf.txt" 2>&1
    case "${arch}" in
        x86_64)  want='AVX-512 required: ' ;;
        aarch64) want='SVE required: ' ;;
        *)       want='== host' ;;
    esac
    if grep -q "${want}" "${work}/rcf.txt"; then
        pass "report_cpu_features reports '$(grep -m1 "${want}" "${work}/rcf.txt" | sed 's/^ *//')' for ${probe##*/}"
    else
        fail "report_cpu_features printed no '${want}' line for ${probe}"
        sed 's/^/      /' "${work}/rcf.txt"
    fi
else
    fail "/container/bin/report_cpu_features is missing"
fi

# 6. OSU and its app contract -- added by the publish stage
osu=/container/app.d/osu
if [ -f "${osu}/app.yaml" ] && [ -x "${osu}/launch" ] && [ -x "${osu}/extract" ]; then
    if grep -q '@OMB_VERSION@' "${osu}/app.yaml"; then
        fail "${osu}/app.yaml still has @OMB_VERSION@ in it"
    else
        bin="$(sed -n 's/^binary: *//p' "${osu}/app.yaml")"
        if [ -x "${bin}" ]; then
            pass "OSU app contract at ${osu}, binary ${bin##*/} present"
        else
            fail "OSU app contract names a binary that is not there: ${bin}"
        fi
    fi
elif [ "${published}" = 1 ]; then
    fail "no OSU app contract at ${osu} (app.yaml, launch, extract)"
else
    skip "OSU app contract: installed by the publish stage (use --published on a published image)"
fi

# 7. OpenBLAS, DYNAMIC_ARCH
if [ -n "${OPENBLAS_ROOT:-}" ] && [ -d "${OPENBLAS_ROOT}" ]; then
    cat > "${work}/blas.c" <<'EOF'
#include <stdio.h>
#include <cblas.h>
int main(void)
{
    double a[4] = {1, 2, 3, 4}, b[4] = {5, 6, 7, 8}, c[4] = {0, 0, 0, 0};
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1.0, a, 2, b, 2, 0.0, c, 2);
    printf("%s|%s\n", openblas_get_corename(), openblas_get_config());
    return !(c[0] == 19 && c[1] == 22 && c[2] == 43 && c[3] == 50);
}
EOF
    if ${CC:-cc} -o "${work}/blas" "${work}/blas.c" -I"${OPENBLAS_ROOT}/include" \
           -L"${OPENBLAS_ROOT}/lib" -Wl,-rpath,"${OPENBLAS_ROOT}/lib" -lopenblas > "${work}/blas.log" 2>&1; then
        if out="$("${work}/blas" 2>&1)"; then
            core="${out%%|*}" cfg="${out#*|}"
            case "${cfg}" in
                *DYNAMIC_ARCH*) pass "OpenBLAS ${OPENBLAS_VERSION:-?}: DGEMM correct, DYNAMIC_ARCH, picked '${core}' on this host" ;;
                *)              fail "OpenBLAS is not a DYNAMIC_ARCH build (config: ${cfg})" ;;
            esac
        else
            fail "OpenBLAS DGEMM gave the wrong answer, or the probe crashed: ${out}"
        fi
    else
        fail "cannot compile and link against OpenBLAS with CC=${CC:-cc}"
        sed 's/^/      /' "${work}/blas.log" | tail -n 20
    fi
else
    fail "OPENBLAS_ROOT is unset or missing ('${OPENBLAS_ROOT:-}')"
fi

# 8. FFTW with its SIMD codelets
case "${arch}" in
    x86_64)  codelets="avx avx2 avx512" ;;
    aarch64) codelets="neon" ;;
    *)       codelets="" ;;
esac
if [ -n "${FFTW_ROOT:-}" ] && [ -d "${FFTW_ROOT}" ]; then
    for prec in "" f; do
        lib="$(ls -d "${FFTW_ROOT}"/lib*/libfftw3${prec}.so 2>/dev/null | head -1)"
        lib="$(readlink -f "${lib}" 2>/dev/null)"
        if [ ! -f "${lib}" ]; then
            fail "no libfftw3${prec}.so under ${FFTW_ROOT}"
            continue
        fi
        missing=""
        for c in ${codelets}; do
            grep -aqE "n1fv_[0-9]+_${c}(\b|_)" "${lib}" || missing="${missing} ${c}"
        done
        if [ -z "${missing}" ]; then
            pass "libfftw3${prec}: SIMD codelets present (${codelets:-none expected on ${arch}})"
        else
            fail "libfftw3${prec}: no${missing} codelets -- configured without its SIMD flags?"
        fi
    done
    # The MPI libraries have no SIMD codelets, so any wide instruction in them
    # means the compiler targeted the build runner's CPU (nvc does, without
    # -tp).  It shows only when that runner had the ISA; the gcc-built serial
    # libraries are not checked this way, as their dispatched codelets are
    # stripped of the names that would set them apart.
    for prec in "" f; do
        mlib="$(readlink -f "$(ls -d "${FFTW_ROOT}"/lib*/libfftw3${prec}_mpi.so 2>/dev/null | head -1)" 2>/dev/null)"
        if [ ! -f "${mlib}" ]; then
            fail "no libfftw3${prec}_mpi.so under ${FFTW_ROOT}"
        elif [ -x /container/bin/report_cpu_features ] \
             && /container/bin/report_cpu_features "${mlib}" 2>/dev/null | grep -q ' required: YES'; then
            fail "libfftw3${prec}_mpi needs $(/container/bin/report_cpu_features "${mlib}" | sed -n 's/^ *\(.*\) required: YES.*/\1/p') -- built for the build runner's CPU, not portably"
        else
            pass "libfftw3${prec}_mpi: no instructions beyond the portable target"
        fi
    done
    cat > "${work}/fft.c" <<'EOF'
#include <stdio.h>
#include <fftw3.h>
int main(void)
{
    int n = 1024;
    fftw_complex *in = fftw_malloc(sizeof(fftw_complex) * n), *out = fftw_malloc(sizeof(fftw_complex) * n);
    fftw_plan p = fftw_plan_dft_1d(n, in, out, FFTW_FORWARD, FFTW_MEASURE);
    fftw_print_plan(p);
    printf("\n");
    fftw_destroy_plan(p); fftw_free(in); fftw_free(out);
    return 0;
}
EOF
    if ${CC:-cc} -o "${work}/fft" "${work}/fft.c" -I"${FFTW_ROOT}/include" -L"$(dirname "${lib}")" \
           -Wl,-rpath,"$(dirname "${lib}")" -lfftw3 -lm > "${work}/fft.log" 2>&1 \
       && "${work}/fft" > "${work}/plan.txt" 2>&1; then
        chose="$(grep -oE '_(sse2|avx2?|avx512|neon)(_128)?' "${work}/plan.txt" | sort | uniq -c | tr -s ' ' | tr '\n' ',' | sed 's/,$//')"
        info "FFTW planner, n=1024 on this host, chose codelets:${chose:- scalar only}"
    else
        info "could not run an FFTW plan probe (see below)"
        sed 's/^/      /' "${work}/fft.log" | tail -n 10
    fi
else
    fail "FFTW_ROOT is unset or missing ('${FFTW_ROOT:-}')"
fi

echo "== the factory's own promises =="

# 9. conda, as asked for
if [ -d /container/miniforge ]; then has_conda=true; else has_conda=false; fi
case "${EXPECT_CONDA:-}" in
    true|false)
        if [ "${EXPECT_CONDA}" = "${has_conda}" ]; then
            pass "Miniforge present: ${has_conda}, as asked"
        else
            fail "Miniforge present: ${has_conda}, but EXPECT_CONDA=${EXPECT_CONDA}"
        fi ;;
    *)  info "Miniforge present: ${has_conda}" ;;
esac

# 10. plainuser owns a few entries, not the tree.  A recursive chown stores a
#     second copy of every file under /container in the final layer.
if id plainuser >/dev/null 2>&1; then
    owned="$(find /container -xdev -user plainuser 2>/dev/null | head -n 1001 | wc -l)"
    if [ "${owned}" -le 10 ]; then
        pass "plainuser owns ${owned} entries under /container (not the whole tree)"
    else
        fail "plainuser owns ${owned}$([ "${owned}" -gt 1000 ] && echo +) entries under /container -- a recursive chown is back"
    fi
else
    info "no plainuser in this image"
fi

echo
if [ "${nfail}" -eq 0 ]; then
    echo "base contract: all checks passed"
else
    echo "base contract: ${nfail} check(s) FAILED"
fi
[ "${nfail}" -eq 0 ]
