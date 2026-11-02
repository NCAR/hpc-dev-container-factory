# The base contract

What every image this factory publishes promises to anything built on it: an
app image, a `.sif` built on a cluster, a user's own `Dockerfile`. Anything not
listed here can change without notice.

The promises are checked by `/container/extras/check_base_contract.sh`, which
ships in every image. CI runs it on every build, and with `--published` on
every published image. On a cluster, run it the same way:

```bash
apptainer exec <image>.sif /container/extras/check_base_contract.sh --published
```

A change to anything below is a change to the contract. Say so in the pull
request, and update this file and the check together.

## 1. Names and tags

```
ghcr.io/ncar/hpcdev-<arch>:<os>-<compiler>-<mpi>[-<gpu>][-conda]-latest
ghcr.io/ncar/hpcdev-<arch>:<os>-<compiler>-<mpi>[-<gpu>][-conda]-<YY.MM>
```

- `<arch>` is `x86_64` or `aarch64`.
- `<compiler>` is the matrix's name for it: `gcc` is the distribution's own
  gcc, `gcc14` is gcc 14 built from source, and `oneapi`, `nvhpc` and `aocc`
  are what they say.
- `<gpu>` is absent for CPU-only images, otherwise `cuda`.
- `-conda` is present only when the image carries Miniforge. Images are built
  without it by default.
- `-latest` moves; `-<YY.MM>` is the month it was built, and is overwritten by
  a rebuild in the same month. Pin a digest for reproducibility.

The images are **portable**: built with no `-march`, so they run on any CPU of
their architecture. nvhpc's `nvc` has no portable default, so its images are
built `-tp=x86-64-v3` (AVX2) on x86_64. Tuning belongs to the layer built on
top, through `MARCH_FLAGS` or an app's own flags.

The check holds only the base's own ELF files to that promise. The factory
lists them in `/container/extras/base-elf.list` as its last build step, and the
check scans that list, so in an image built on this one it passes whatever
target the new layer was built for. A layer that replaces a listed file in
place is held to the promise for that file.

`ghcr.io/ncar/hpcdev-<arch>-cache` holds build cache and CI intermediates. It
is not part of the contract.

## 2. The environment

- **`/container/config_env.sh`** sets the whole environment of the image:
  `PATH`, `CPATH`, `LIBRARY_PATH`, `LD_LIBRARY_PATH`, the compilers and each
  library's root. Every login shell sources it, through the link
  `/etc/profile.d/z00-build-env.sh`. Anything run outside a login shell --
  `apptainer exec`, `docker exec`, `docker run --entrypoint` -- should source
  it first.
- **The entrypoint is a login shell** that runs its arguments as one command
  line: `bash --login -c '${*}' --`. The command inherits the environment the
  login shell exported. Pass a command as plain words
  (`docker run <img> mpicc --version`), not as `bash -lc '<script>'`, which
  runs only the script's first word.
- **`/container/extras/build_common.cfg`**, sourced by a build script, sets
  `INSTALL_ROOT` (`/container`) and `STAGE_DIR` (`/tmp`). Install under
  `${INSTALL_ROOT}` and build under `${STAGE_DIR}`.
- **`MARCH_FLAGS`** is exported by `config_env.sh` in every image, empty in a
  portable one. A build script passes it on the compile line (a compiler
  wrapper does not read `CFLAGS`), so an image built for a target builds its
  apps for that target. Its spelling is the compiler's: `-march=` for GNU and
  LLVM, `-tp=` for nvhpc.
- **`CC`, `CXX`, `FC` and `F77`** are the MPI compiler wrappers. `mpicc`,
  `mpicxx` and `mpifort` are on `PATH`, and `MPICC`, `MPICXX`, `MPIFC` and
  `MPIF77` name them. `COMPILER_FAMILY` and `MPI_FAMILY` say which they wrap.
- The image runs as `root`. A `plainuser` account exists, with passwordless
  `sudo`, and owns `/container`, `config_env.sh` and `/container/logs/`.

## 3. Tools every image carries

These are in the base because every container run on a cluster depends on
them: they are how an image shows that it works on a host, before any app is
involved.

- **`/container/bin/report_placement`** -- a hybrid MPI and OpenMP program that
  reports where each rank and thread runs. Its source and build script are in
  `/container/extras/` (`report_placement.cxx`, `build_report-placement.sh`).
- **`/container/bin/report_cpu_features [binary]`** -- the host's SIMD
  features, and, given a binary, the instruction set it needs. These lines are
  read by other tools and keep their wording:

  | Line | Means |
  |---|---|
  | `  ISA flags: ...` | the x86_64 host's SIMD flags |
  | `  SIMD: ...` | the aarch64 host's |
  | `  AVX-512 (zmm) used by binary: YES\|no` | an AVX-512 register is named anywhere in the binary |
  | `  AVX-512 required: YES\|no ...` | an AVX-512 instruction -- on `%zmm`, or EVEX on `%xmm`/`%ymm` (AVX-512VL) -- outside routines that dispatch at run time (Intel's SVML, OpenBLAS's and FFTW's kernels): **YES means the binary needs an AVX-512 host**. Found by register, mask, broadcast and AVX-512-only mnemonic, so `no` means none was found, not a proof |
  | `  SVE (z-regs) used by binary: ...`, `  SVE required: ...` | the same, for SVE on aarch64 |

  The functions behind the answer are listed between those lines. An "ISA
  needed" ELF note means something only for a binary built with gcc
  `-mneeded`.
- **OSU Micro-Benchmarks, with their app contract at `/container/app.d/osu/`**
  (`app.yaml`, `launch`, `extract`), added when an image is published. The app
  contract itself is described in `/container/extras/app.d/README.md`.

## 4. Libraries

Each library is installed under its own versioned prefix in `/container`, is
on `CPATH`, `LIBRARY_PATH` and the dynamic linker's path, and has a variable
naming its root. Versions are not part of the contract; the variables are.

| Library | Variables | Notes |
|---|---|---|
| HDF5 (parallel), szip, c-blosc | `HDF5_VERSION`, `SZIP_VERSION`, `BLOSC_VERSION` | Fortran and high-level interfaces |
| NetCDF C and Fortran | `NETCDF`, `NETCDF_C_VERSION`, `NETCDF_FORTRAN_VERSION`, `HDF5_PLUGIN_PATH` | |
| PnetCDF | `PNETCDF`, `PNETCDF_VERSION` | |
| ParallelIO | `PIO`, `PIO_VERSION` | |
| **OpenBLAS** | `OPENBLAS_ROOT`, `OPENBLAS_VERSION` | `DYNAMIC_ARCH`: picks its kernels from CPUID when it loads, AVX-512 where the host has it. BLAS and CBLAS (`cblas.h`, `-lopenblas`) only -- **no LAPACK** -- and single-threaded. |
| **FFTW** | `FFTW_ROOT`, `FFTW_VERSION` | double and single precision, threads, MPI. Built with its SIMD codelets (SSE2 to AVX-512 on x86_64, NEON on aarch64), which its planner chooses from at run time. |
| HeFFTe | `HEFFTE_ROOT`, `HEFFTE_VERSION` | on FFTW; CUDA too in a CUDA image |

The libraries an app gets the most from on a newer CPU are the ones that
dispatch at run time, which is why these two are built that way: a portable
image then delivers AVX-512 where it pays without an image per node type. What
dispatch cannot reach is an app's own loops; build those with the app's flags.

## 5. Not promised

- Miniforge (conda). Present only in a `-conda` image.
- Any particular version of a compiler, MPI or library. They are in the
  image's labels (`docker inspect`) and in `config_env.sh`.
- That the MPI in the image is the one that runs. On a cluster the host's MPI
  usually replaces it at run time; build against the wrappers, and do not
  depend on the implementation's internals.
- The contents of `/container/extras/` beyond the files named above. It holds
  the factory's build and test scripts, which change with the factory.
