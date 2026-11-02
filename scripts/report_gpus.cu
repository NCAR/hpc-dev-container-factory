//------------------------------------------------------------------------------
// report_gpus -- which GPUs this process sees, and from where.
//
// The GPU companion to report_placement: that one says which CPUs each rank
// landed on, this one says which GPUs one process can use, which driver it got
// them through, and whether a kernel runs.  Installed in every CUDA image as
// /container/bin/report_gpus (CONTRACT.md section 5).
//
// It is not an MPI program.  Launch one copy per rank (mpiexec ... report_gpus)
// and each copy names its rank from the launcher's environment, so a per-rank
// device binding can be checked without an app.
//
// Output, one header line and one line per visible device, all beginning
// "report_gpus:" so a caller can grep them out of a log.  Keys are stable;
// a value that cannot be found is "-".
//
//   report_gpus: host=deg0051 rank=0 local=0 cpus=0-15 libcuda=/host_lib64/libcuda.so.1
//                driver=13000 runtime=12090 devices=1 status="no error"
//                CUDA_VISIBLE_DEVICES=3
//   report_gpus: host=deg0051 rank=0 device=0 bus=0000:c1:00.0 numa=0
//                uuid=GPU-997247d2-... cc=8.0 mem_mib=40441 name="NVIDIA A100-SXM4-40GB"
//   report_gpus: host=deg0051 rank=0 kernel=ok
//
// (each record is one line; they are wrapped here only for width).
//
// Exit status: 0 when at least one device is visible and a kernel ran on the
// first; 2 when there is no usable device (no GPU, or the driver is the image's
// stub because the host's was not made visible -- apptainer --nv); 3 when a
// device is visible but the kernel failed.
//
// Build: nvcc -O2 -o report_gpus report_gpus.cu   (NVCC_PREPEND_FLAGS supplies
// -arch=all-major, so the device code runs on every GPU generation since sm_50).
//------------------------------------------------------------------------------
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <link.h>
#include <sched.h>
#include <unistd.h>
#include <cuda_runtime.h>

static std::string libcuda_path = "-";

static int find_libcuda(struct dl_phdr_info *info, size_t, void *)
{
    if (info->dlpi_name && strstr(info->dlpi_name, "libcuda.so"))
        libcuda_path = info->dlpi_name;
    return 0;
}

// The first variable of these that is set, or "-".
static const char *first_env(const char *const *names)
{
    for (; *names; ++names) {
        const char *v = getenv(*names);
        if (v && *v)
            return v;
    }
    return "-";
}

// This process's CPU affinity as a range list, 0-15,64-79.
static std::string cpu_list()
{
    cpu_set_t set;
    if (sched_getaffinity(0, sizeof set, &set) != 0)
        return "-";
    std::string out;
    for (int c = 0; c < CPU_SETSIZE; ++c) {
        if (!CPU_ISSET(c, &set))
            continue;
        int e = c;
        while (e + 1 < CPU_SETSIZE && CPU_ISSET(e + 1, &set))
            ++e;
        if (!out.empty())
            out += ",";
        out += std::to_string(c);
        if (e > c)
            out += "-" + std::to_string(e);
        c = e;
    }
    return out.empty() ? "-" : out;
}

// The NUMA domain sysfs gives the PCI device, or "-".
static std::string numa_of(const char *bus)
{
    std::string path = std::string("/sys/bus/pci/devices/") + bus + "/numa_node";
    FILE *f = fopen(path.c_str(), "r");
    if (!f)
        return "-";
    int n = -1;
    int got = fscanf(f, "%d", &n);
    fclose(f);
    return (got == 1 && n >= 0) ? std::to_string(n) : "-";
}

__global__ void axpy(int n, double a, const double *x, double *y)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
        y[i] += a * x[i];
}

int main()
{
    static const char *const rank_vars[] = {"PMI_RANK", "PALS_RANKID", "OMPI_COMM_WORLD_RANK",
                                            "PMIX_RANK", "SLURM_PROCID", nullptr};
    static const char *const local_vars[] = {"PMI_LOCAL_RANK", "PALS_LOCAL_RANKID",
                                             "OMPI_COMM_WORLD_LOCAL_RANK", "MPI_LOCALRANKID",
                                             "SLURM_LOCALID", nullptr};
    char host[256] = "-";
    gethostname(host, sizeof host);
    host[sizeof host - 1] = '\0';
    if (char *dot = strchr(host, '.'))
        *dot = '\0';
    const char *rank = first_env(rank_vars);
    const char *visible = getenv("CUDA_VISIBLE_DEVICES");

    int ndev = 0, driver = 0, runtime = 0;
    cudaError_t status = cudaGetDeviceCount(&ndev);
    if (status != cudaSuccess)
        ndev = 0;
    cudaDriverGetVersion(&driver);
    cudaRuntimeGetVersion(&runtime);
    dl_iterate_phdr(find_libcuda, nullptr);

    printf("report_gpus: host=%s rank=%s local=%s cpus=%s libcuda=%s driver=%d runtime=%d "
           "devices=%d status=\"%s\" CUDA_VISIBLE_DEVICES=%s\n",
           host, rank, first_env(local_vars), cpu_list().c_str(), libcuda_path.c_str(), driver,
           runtime, ndev, cudaGetErrorString(status), visible ? visible : "(unset)");

    for (int d = 0; d < ndev; ++d) {
        cudaDeviceProp p;
        if (cudaGetDeviceProperties(&p, d) != cudaSuccess)
            continue;
        char bus[32] = "-";
        cudaDeviceGetPCIBusId(bus, sizeof bus, d);
        for (char *c = bus; *c; ++c)
            *c = (char)tolower((unsigned char)*c);   // sysfs spells it in lower case
        const unsigned char *u = reinterpret_cast<const unsigned char *>(p.uuid.bytes);
        printf("report_gpus: host=%s rank=%s device=%d bus=%s numa=%s "
               "uuid=GPU-%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x "
               "cc=%d.%d mem_mib=%zu name=\"%s\"\n",
               host, rank, d, bus, numa_of(bus).c_str(), u[0], u[1], u[2], u[3], u[4], u[5], u[6],
               u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15], p.major, p.minor,
               p.totalGlobalMem >> 20, p.name);
    }
    if (ndev == 0)
        return 2;

    // y = 2 x on x = 1, so the last element is 2.0 only if every block ran.
    const int n = 1 << 20;
    std::vector<double> ones(n, 1.0);
    double *x = nullptr, *y = nullptr, y_last = 0;
    cudaError_t k = cudaMalloc(&x, n * sizeof(double));
    if (k == cudaSuccess)
        k = cudaMalloc(&y, n * sizeof(double));
    if (k == cudaSuccess)
        k = cudaMemcpy(x, ones.data(), n * sizeof(double), cudaMemcpyHostToDevice);
    if (k == cudaSuccess)
        k = cudaMemset(y, 0, n * sizeof(double));
    if (k == cudaSuccess) {
        axpy<<<(n + 255) / 256, 256>>>(n, 2.0, x, y);
        // A launch can fail at once -- no machine code for this device, say --
        // without queueing anything, and the synchronize after it then succeeds.
        k = cudaGetLastError();
    }
    if (k == cudaSuccess)
        k = cudaDeviceSynchronize();
    if (k == cudaSuccess)
        k = cudaMemcpy(&y_last, y + n - 1, sizeof y_last, cudaMemcpyDeviceToHost);
    cudaFree(x);
    cudaFree(y);
    const bool ok = k == cudaSuccess && y_last == 2.0;
    printf("report_gpus: host=%s rank=%s kernel=%s\n", host, rank,
           ok ? "ok" : k != cudaSuccess ? cudaGetErrorString(k) : "wrong result");
    return ok ? 0 : 3;
}
