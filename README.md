# cells2stats on Biowulf

Singularity-based workflow for running [cells2stats](https://docs.elembio.io/docs/cells2stats/introduction/) (Element Biosciences AVITI cell imaging pipeline) on the NIH Biowulf cluster.

- **cells2stats:** 1.3.1
- **Base image:** `elembio/cells2stats:latest` (Ubuntu 22.04)
- **Bundled:** bases2fastq, CellProfiler (Python 3.8 venv at `/opt/cellprofiler`), MultiQC, samtools, bowtie/bowtie-build (added in def file), Python 3.10 with zarr/tifffile/cv2/skimage/geopandas/pyarrow stack for visualization
- **Maintained by:** HiTIF

---

## Repository layout

```
cells2stats/
├── defs/
│   └── cells2stats-full.def    # Singularity definition file
├── scripts/
│   ├── run_cells2stats.sh      # sbatch wrapper (submit from here)
│   └── logs/                   # SLURM stdout/stderr — created on first use
├── runs/                       # input AVITI run directories (or symlinks)
│   └── <RUN_NAME>/
├── outputs/                    # cells2stats output directories
│   └── <RUN_NAME>/
└── README.md                   # this file
```

The built SIF lives **outside** this repo at `/data/$USER/containers/cells2stats/cells2stats-full.sif` (the wrapper hardcodes this path). Keep it there; the repo `containers/` directory, if it exists, is orphaned.

---

## 1. Building the container

The prebuilt image lives at `/data/$USER/containers/cells2stats/cells2stats-full.sif`. Rebuild only when the def file changes or the upstream `elembio/cells2stats:latest` is updated.

> **Note on paths:** on Biowulf, `/data/$USER` is an alias (symlink) for `/vf/users/$USER`. Either path works; container bindpaths handle both transparently. This document uses `/data/$USER` throughout for brevity.

### Prerequisites

- A Biowulf account with `/data/$USER` quota of at least ~10 GB free (SIF + build cache).
- An interactive node. **Do not build on a login node** — pulling and assembling the image is CPU- and I/O-heavy.

### Steps

1. Grab an interactive session with enough memory and local scratch:

   ```bash
   sinteractive --cpus-per-task=4 --mem=16g --gres=lscratch:50 --time=2:00:00
   ```

2. Load Singularity:

   ```bash
   module load singularity
   ```

3. Point Singularity's cache and tmp away from `$HOME` (the default `$HOME/.singularity` will fill your home quota with multi-GB layers):

   ```bash
   export SINGULARITY_CACHEDIR=/data/$USER/.singularity_cache
   export SINGULARITY_TMPDIR=/lscratch/$SLURM_JOB_ID
   mkdir -p "$SINGULARITY_CACHEDIR"
   ```

4. Build the SIF. Biowulf doesn't grant `--fakeroot`; the unprivileged `proot`-backed default works fine for this def file:

   ```bash
   cd /data/$USER/containers/cells2stats
   singularity build cells2stats-full.sif /data/$USER/cells2stats/defs/cells2stats-full.def
   ```

   The build pulls the Docker image, installs `bowtie` via apt, and runs the `%test` block. If `%test` fails (missing binary, broken Python import) the build aborts — fix the def file and retry.

5. Verify:

   ```bash
   singularity exec cells2stats-full.sif cells2stats --version
   singularity exec cells2stats-full.sif /opt/cellprofiler/bin/python3 -c \
       "import cellprofiler; print(cellprofiler.__version__)"
   ```

### Notes on the def file

- The `%post` block is intentionally minimal — only `bowtie` is added on top of the upstream image. Keep additions there to preserve reproducibility.
- The `%test` block runs at build time and is the contract for what the container guarantees. Add any new dependency check there.
- Two Python interpreters coexist: system `/usr/bin/python3` (3.10, has the viz/zarr stack) and `/opt/cellprofiler/bin/python3` (3.8, has CellProfiler). Don't mix them.

---

## 2. Submitting a run

### Inputs

cells2stats expects an **AVITI run directory** — the output folder from a Cytoprofiling run on the instrument, containing `RunManifest.json`/`RunManifest.csv`, `RunParameters.json`, and the per-cycle image data. In this repo, place them in `runs/` (or symlink from there to wherever the data actually lives):

```
/data/$USER/cells2stats/runs/<RUN_NAME>/
```

### First-time setup

The wrapper's `#SBATCH --output=logs/c2s_%j.out` directive is evaluated by the SLURM controller **before** the script body runs, so the `logs/` directory must exist relative to wherever you `sbatch` from. The wrapper is designed to be submitted from `scripts/`, so create `scripts/logs/` once:

```bash
cd /data/$USER/cells2stats/scripts
mkdir -p logs
```

Always submit from `scripts/` (or the SLURM output files will land somewhere unexpected, or the job will fail to start).

### Submitting

```bash
cd /data/$USER/cells2stats/scripts
sbatch run_cells2stats.sh RUN_DIR OUT_DIR [extra cells2stats args...]
```

Examples (using the repo's own `runs/` and `outputs/` directories for input/output):

```bash
# Full run (CellProfiler + visualization), no TCA
sbatch run_cells2stats.sh \
    /data/$USER/cells2stats/runs/20260522_AV254504_Fixed_Slide_Test \
    /data/$USER/cells2stats/outputs/20260522_AV254504_Fixed_Slide_Test \
    --visualization

# With target cell assignment (TCA) manifest
sbatch run_cells2stats.sh \
    /data/$USER/cells2stats/runs/<RUN_NAME> \
    /data/$USER/cells2stats/outputs/<RUN_NAME> \
    --visualization --tca-manifest /data/$USER/manifests/tca.csv

# Visualization only — skips CellProfiler and stats regeneration, much faster
sbatch run_cells2stats.sh \
    /data/$USER/cells2stats/runs/<RUN_NAME> \
    /data/$USER/cells2stats/outputs/<RUN_NAME> \
    --visualization-only

# Stats only — skip CellProfiler (no morphology features)
sbatch run_cells2stats.sh \
    /data/$USER/cells2stats/runs/<RUN_NAME> \
    /data/$USER/cells2stats/outputs/<RUN_NAME> \
    --skip-cellprofiler
```

The wrapper resolves both paths with `readlink -f`, validates `RUN_DIR` exists, creates `OUT_DIR`, and forwards everything after the first two arguments verbatim to `cells2stats`.

### What the wrapper does for you

- Loads the `singularity` module (unversioned, per Biowulf policy — staff retire versioned modules without notice).
- Sources `/usr/local/current/singularity/app_conf/sing_binds` so GPFS-backed paths (`/data`, `/vf`, `/fdb`, etc.) are visible inside the container via Biowulf staff-maintained bindpaths.
- Adds `/lscratch/$SLURM_JOB_ID → /tmp` so cells2stats' temporary files land on fast local SSD instead of GPFS.
- Sets `TMPDIR=/tmp` inside the container.
- Pins all BLAS/OMP thread counts to 1, and caps OpenCV and ITK thread pools the same way (see [Troubleshooting → RLIMIT_NPROC](#runtimeerror-cant-start-new-thread--rlimit_nproc-explosion) and [Troubleshooting → OpenCV thread spawn errors during visualization](#opencv-cant-spawn-new-thread-errors-during-visualization)).
- Constrains the per-worker JVM (heap, GC threads, stack) that CellProfiler spawns for Bioformats, to prevent the JVM-side equivalent of the BLAS thread explosion (see [Troubleshooting → JVM crash dumps](#jvm-crash-dumps-hs_err_pidlog)).
- Passes `--num-threads $SLURM_CPUS_PER_TASK` so cells2stats matches the SLURM allocation.
- Passes `--output $OUT_DIR` from the second positional argument.
- **Rejects** `--output`/`-o`/`--num-threads`/`-j` if passed as extra args (the wrapper manages them; double-setting confuses cells2stats).
- Captures the cells2stats exit code and prints a start/end banner with job ID, node, allocation, and Singularity version for post-mortem.

### Monitoring

```bash
squeue -u $USER
sjobs                          # Biowulf helper
tail -f /data/$USER/cells2stats/scripts/logs/c2s_<JOBID>.out
```

After completion, check resource use to right-size future runs:

```bash
jobhist <JOBID>
```

---

## 3. Common parameters

### SLURM resources (edit at the top of `run_cells2stats.sh`)

| Directive             | Default        | When to change                                                                       |
| --------------------- | -------------- | ------------------------------------------------------------------------------------ |
| `--partition`         | `norm`         | `quick` for ≤4 h tests; `largemem` if you hit OOM on `norm` (max 247 GB).             |
| `--cpus-per-task`     | 32             | Lower (8–16) for small runs or visualization-only; higher hits diminishing returns. |
| `--mem`               | 128g           | Bump to 247g for large CellProfiler runs with many cells per FOV.                    |
| `--gres=lscratch:100` | 100 GB         | Increase to 200–400 GB for runs with many cycles or large image sets.                |
| `--time`              | 4:00:00        | Full runs with CellProfiler + viz often take 6–12 h; raise to `12:00:00` or more.    |

### cells2stats arguments (most-used subset)

The full, authoritative reference is at **<https://docs.elembio.io/docs/cells2stats/optional-arguments/>**. The subset below is what you'll reach for day-to-day on Biowulf.

| Flag (short)                       | Effect                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------ |
| `--output DIR` (`-o`)              | Output directory. **Set by the wrapper — don't pass it again.** Default would otherwise be `INPUT_DIR/CYTOPROFILING/<TIMESTAMP>`. |
| `--num-threads N` (`-j`)           | Parallel workers. **Set by the wrapper from `$SLURM_CPUS_PER_TASK`** — don't pass it again. |
| `--visualization` (`-V`)           | Generate CytoCanvas input files alongside stats. Adds significant runtime; required if using alternative segmentation masks via `--segmentation` and wanting full regeneration. |
| `--visualization-only` (`-O`)      | CytoCanvas inputs only; skips stats and CellProfiler. Use to prep an existing run output for visualization. |
| `--skip-cellprofiler` (`-s`)       | Run without CellProfiler. Morphology features will not appear in `RawCellStats.csv`/`.parquet`. |
| `--skip-html-report` (`-H`)        | Skip MultiQC HTML report generation.                                                       |
| `--tca-manifest FILE.csv`          | Target cell assignment manifest (CSV).                                                     |
| `--run-manifest FILE.csv` (`-r`)   | Use a corrected run manifest instead of the one on the instrument output. See Element's [Run Manifest docs](https://docs.elembio.io/docs/run-manifest/#corrected-run-manifest). |
| `--panel FILE.json` (`-p`)         | Use an alternate `panel.json` instead of the instrument-emitted one.                        |
| `--segmentation DIR` (`-S`)        | Directory of alternative cell segmentation masks. See Element's [resegmentation tutorial](https://docs.elembio.io/docs/tutorials/cytoprofiling/resegmentation/). |
| `--batch B1,B2,...` (`-b`)         | Restrict analysis to specific batches. Valid: `B1`–`B8`.                                    |
| `--well A1,B2,...` (`-w`)          | Restrict to specific wells. 12-well: `A1`–`F2`; 48-well: `A1`–`L4`.                          |
| `--tile 'REGEX'` (`-t`)            | Restrict to tiles matching a regex (e.g. `'L1R..C..S.'` for all of Lane 1). Repeatable.    |
| `--max-unassigned N` (`-u`)        | Max number of unassigned sequences reported (1–10000, default 30).                          |
| `--log-level LEVEL` (`-l`)         | `INFO` (default), `DEBUG`, `WARNING`, `ERROR`. Use `DEBUG` when filing bug reports.         |
| `--error-on-missing` (`-m`)        | Fail on missing input files instead of skipping them.                                       |
| `--no-error-on-invalid` (`-n`)     | Skip invalid files and continue (the default is also to skip; this is the explicit form).   |
| `--verbose-transfer` (`-T`)        | Print filenames during log/file transfer.                                                   |

> **Don't pass these from the command line on Biowulf**, because the container provides them and the wrapper would conflict: `--bases2fastq`, `--bowtie`, `--bowtie-build`, `--cellprofiler`, `--samtools`, `--python`. These flags exist for non-containerized installs that need to point at host binaries.

The `--input-remote` / `--output-remote` rclone flags also aren't relevant on Biowulf — keep data on `/data` (= `/vf/users`) and let the bindpath handle it.

Run `singularity exec $CONTAINER cells2stats --help` for the live, version-specific argument list.

---

## 4. Troubleshooting

### Container not found

```
Container not found: /data/$USER/containers/cells2stats/cells2stats-full.sif
```

You're running someone else's submission, or you haven't built it yet. The wrapper resolves `$USER` per-submitter. Either build your own copy (Section 1) or edit `CONTAINER=` in the wrapper to point at a shared lab build.

### `RUN_DIR not found`

The wrapper calls `readlink -f` before validating. If the path is on `/vf/users/...` and you submitted from a node that hasn't refreshed the automount, the path may briefly fail. `cd` into the directory once from the submit host before resubmitting.

### Job dies immediately with `singularity: command not found`

The wrapper runs `module load singularity` (unversioned, per Biowulf policy). If `module` itself isn't found, your shell environment is wiping `MODULEPATH` — submit from a clean login shell.

If the Singularity default has just been bumped on Biowulf and the SIF misbehaves with the new version (rare but possible), rebuild the SIF against the current default to confirm compatibility before debugging further.

### `ERROR: do not pass '--output' as an extra argument`

You passed `--output`/`-o` or `--num-threads`/`-j` in the extra-args position. The wrapper manages these — drop them from your `sbatch` command line.

### `RuntimeError: can't start new thread` / RLIMIT_NPROC explosion

cells2stats spawns one Python worker per `--num-threads`. Without thread-pinning, each worker's numpy spawns another N BLAS threads, giving N² total — at 32 CPUs that's 1024 threads, exactly the per-user `RLIMIT_NPROC` ceiling on Biowulf compute nodes. The wrapper pins these to 1:

```
SINGULARITYENV_OPENBLAS_NUM_THREADS=1
SINGULARITYENV_MKL_NUM_THREADS=1
SINGULARITYENV_OMP_NUM_THREADS=1
SINGULARITYENV_NUMEXPR_NUM_THREADS=1
SINGULARITYENV_BLIS_NUM_THREADS=1
```

If you copy the wrapper and remove these, expect this error around the time the first worker pool ramps up. Don't.

### OpenCV `Can't spawn new thread` errors during visualization

Symptom in `scripts/logs/c2s_<JOBID>.out` — many lines like:

```
[ERROR:0@119.582] global parallel_impl.cpp:244 WorkerThread 19: Can't spawn new thread: res = 11
[ERROR:0@119.616] global parallel_impl.cpp:244 WorkerThread 20: Can't spawn new thread: res = 11
...
Failed to handle cell border calculation for .../WellB1/L2R06C01S1_Cell.tif with error can't start new thread
Failed to handle cell border calculation for .../WellB1/L2R06C02S1_Cell.tif with error can't start new thread
...
```

**The job exits 0 but the output is incomplete.** The visualization preprocessing script catches the per-tile failure, skips that tile, and moves on. Affected tiles will be missing or have empty cell-border data in the CytoCanvas visualization output. Easy to miss if you only check the exit code.

This is the same root cause as the [RLIMIT_NPROC explosion above](#runtimeerror-cant-start-new-thread--rlimit_nproc-explosion) — `res = 11` is errno `EAGAIN` from `pthread_create`, which on Linux almost always means the per-user thread/process ceiling has been hit. But it's a **different culprit:**

- The BLAS pinning above covers numpy/scipy worker threads.
- The JVM `JAVA_TOOL_OPTIONS` below covers CellProfiler's Bioformats JVMs.
- **OpenCV** (`cv2`), used by the visualization preprocessing script for per-tile image processing, does NOT honor `OMP_NUM_THREADS` unless it was built with OpenMP — which the upstream cells2stats image is not. cv2 queries the host CPU count directly (192 on Biowulf EPYC 9454 nodes) and tries to spin up that many threads in each `cv2.parallel_for_` region. With 32 viz-preprocessing workers each doing this, you blow past `RLIMIT_NPROC=1024` even with all the other pins in place.

**Fix (already in this wrapper):** the wrapper sets

```
SINGULARITYENV_OPENCV_FOR_THREADS_NUM=1
SINGULARITYENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
```

After applying these, verify the next run with:

```bash
grep -c "Can't spawn new thread" scripts/logs/c2s_<JOBID>.out          # should be 0
grep -c "Failed to handle cell border" scripts/logs/c2s_<JOBID>.out    # should be 0
```

If you submitted a run before this fix was in place, the resulting output is salvageable: rerun the same job with `--visualization-only` (the wrapper's default behavior for that mode will re-emit the missing tiles into the same output directory).

### Out of disk space mid-run

cells2stats writes a lot of intermediate data to `$TMPDIR`. The wrapper binds `/lscratch/$JOBID` (sized by `--gres=lscratch:N`) to `/tmp`. If you see `No space left on device`, increase `--gres=lscratch:` (allowed up to 800 GB on most `norm` nodes; check `freen`).

### Out of memory (OOM) — job killed by SLURM

Symptom in `scripts/logs/c2s_<JOBID>.err`:

```
slurmstepd: error: Detected 1 oom-kill event(s)
```

Options, in order of preference:

1. Raise `--mem` (up to 247g on `norm`).
2. Lower `--cpus-per-task` — fewer parallel workers = less peak memory.
3. Switch to `--partition=largemem` and request more.

Re-running with `--tile`, `--well`, or `--batch` on a smaller subset is also a useful way to bisect whether a specific region is responsible.

### GPFS / bindpath issues — "No such file or directory" inside container

Symptom: `cells2stats` reports the run dir doesn't exist, but it clearly does on the host. The wrapper sources `/usr/local/current/singularity/app_conf/sing_binds` to handle this; if you've overridden `SINGULARITY_BINDPATH` in your shell, your override wins and may drop required mounts. Unset it before submitting:

```bash
unset SINGULARITY_BINDPATH
```

### CellProfiler import errors

If `--skip-cellprofiler` works but a full run fails inside CellProfiler, you may have built against an updated upstream image with a broken venv. Rerun `singularity exec $SIF /opt/cellprofiler/bin/python3 -c "import cellprofiler"` against the SIF. If it fails, rebuild from the def file (the `%test` block would have caught it at build time, so this implies your SIF is stale or partial).

### JVM crash dumps (`hs_err_pid*.log`)

CellProfiler shells out to a JVM (via Bioformats) to read image formats. When that JVM dies it drops `hs_err_pid<PID>.log` in the current working directory — for jobs submitted via this wrapper that's `scripts/`.

**The most likely cause is *not* a Java OOM**, despite what the dump's "Out of Memory Error" header suggests. Open the file and look at the stack near the top:

```
V  [libjvm.so+...]  AbstractWorkGang::add_workers(...)
V  [libjvm.so+...]  G1ConcurrentMark::G1ConcurrentMark(...)
V  [libjvm.so+...]  G1CollectedHeap::initialize()
```

A crash during `G1CollectedHeap::initialize` / `AbstractWorkGang::add_workers`, with elapsed time under a second, is the JVM dying while trying to spawn its garbage-collector worker threads — **not** while running out of heap. The system has plenty of RAM; what's been exhausted is the per-user thread/process limit (`RLIMIT_NPROC=1024` on Biowulf).

**Why it happens:** the JVM auto-sizes its GC thread pool from the *host* CPU count (192 on the AMD EPYC 9454 nodes), not from `$SLURM_CPUS_PER_TASK`. With 32 cells2stats workers each forking a JVM that wants ~30 native threads on init, you can easily blow past 1024.

**Fix (already in this wrapper):** the wrapper sets

```
SINGULARITYENV_JAVA_TOOL_OPTIONS="-Xmx4g -Xms512m -XX:ParallelGCThreads=2 -XX:ConcGCThreads=1 -XX:CICompilerCount=2 -Xss512k"
```

This caps the per-JVM heap to 4 GB, pins the GC and JIT thread pools to small fixed values, and shrinks per-thread stack reservation. To confirm the flags are reaching the JVM, look near the start of `c2s_<JOBID>.out` for:

```
Picked up JAVA_TOOL_OPTIONS: -Xmx4g -Xms512m -XX:ParallelGCThreads=2 ...
```

If that line is missing, the env var isn't crossing the Singularity boundary — verify the `SINGULARITYENV_` prefix is intact.

**Other things that produce hs_err_pid files (less common):**

1. **Actual Java heap OOM.** Stack will say `java.lang.OutOfMemoryError: Java heap space` (not `Cannot create worker GC thread`). Fix: raise `-Xmx` in the wrapper's `JAVA_TOOL_OPTIONS` from `4g` to `8g`.
2. **Corrupt or truncated image data.** Look for a file path near the top of the dump. A single bad TIFF can crash the Bioformats reader.
3. **Genuine SLURM-side OOM.** Whole job killed by `slurmstepd` (see [OOM section](#out-of-memory-oom--job-killed-by-slurm)). The hs_err files are a side effect, not the cause.

The dump files themselves are harmless artifacts; safe to delete after diagnosis. To stop them cluttering the repo, add `scripts/hs_err_pid*.log` and `scripts/core.*` to `.gitignore`.

### Build fails at `%test`

A test command exited non-zero. Read the build log carefully — it's almost always either (a) a Python import that the upstream image dropped, or (b) `apt-get` failing because the package list expired (`%post` rebuilds it; re-run the build).

### Slow visualization output

`--visualization` writes CytoCanvas input files to `OUT_DIR`. If `OUT_DIR` is on `/data` (GPFS), it will be slower than `/lscratch`. For very large viz outputs, write to `/lscratch/$JOBID/out` and `rsync` the result to `/data` at the end of the script.

### Diagnosing with `--log-level DEBUG`

When opening a support thread or filing a bug, rerun the failing job with `--log-level DEBUG` appended to the `sbatch` arguments. The verbose log goes to `scripts/logs/c2s_<JOBID>.out` alongside the cells2stats internal log inside `OUT_DIR`.

---

## References

- cells2stats documentation: <https://docs.elembio.io/docs/cells2stats/introduction/>
- All optional arguments: <https://docs.elembio.io/docs/cells2stats/optional-arguments/>
- Biowulf Singularity guide: <https://hpc.nih.gov/apps/singularity.html>

## Contact

HiTIF — Gianluca Pegoraro. Open an issue in this repo for bugs or improvement requests.
