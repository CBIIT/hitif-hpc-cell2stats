# cells2stats on Biowulf

Singularity-based workflow for running [cells2stats](https://docs.elembio.io/docs/cells2stats/introduction/) (Element Biosciences AVITI cell imaging pipeline) on the NIH Biowulf cluster.

- **cells2stats:** 1.4.0-beta (image tag `elembio/cells2stats:1.4.0-beta`; `cells2stats --version` reports `1.4.0.<build>-beta`)
- **Base image:** `elembio/cells2stats:1.4.0-beta` (Ubuntu 22.04)
- **Bundled:** bases2fastq 2.4.0, CellProfiler (Python 3.8 venv at `/opt/cellprofiler`), MultiQC 1.35, samtools 1.13, bowtie/bowtie-build 1.3.1 (added in def file). The visualization + **SpatialData** stack (zarr, tifffile, cv2, skimage, geopandas, pyarrow, ome-zarr, scipy, **spatialdata**) lives in **Python 3.11** (`/usr/bin/python3.11`); the default `/usr/bin/python3` is a bare 3.10.
- **Maintained by:** HiTIF

> **Upgrading from 1.3.1?** See [What changed in 1.4](#0-what-changed-in-14-vs-131) below — several flags were removed and visualization now runs by default. The 1.3.1 SIF, def, and wrapper are retained alongside the 1.4.0 ones (see [Legacy 1.3.1](#legacy-131)).

---

## Repository layout

```
cells2stats/
├── defs/
│   ├── cells2stats-full.def        # 1.3.1 Singularity definition (legacy)
│   └── cells2stats-1.4.0.def       # 1.4.0 Singularity definition (current)
├── scripts/
│   ├── run_cells2stats.sh          # 1.3.1 sbatch wrapper (legacy)
│   ├── run_cells2stats_1.4.0.sh    # 1.4.0 sbatch wrapper (submit from here)
│   └── logs/                       # SLURM stdout/stderr — created on first use
├── runs/                           # input AVITI run directories (or symlinks)
│   └── <RUN_NAME>/
├── outputs/                        # cells2stats output directories
│   └── <RUN_NAME>/
└── README.md                       # this file
```

The built SIFs live **outside** this repo at `/data/$USER/containers/cells2stats/` (the wrappers hardcode these paths). The 1.4.0 wrapper points at `cells2stats-full-1.4.0.sif`; the 1.3.1 wrapper still points at `cells2stats-full.sif`. Keep both there.

---

## 0. What changed in 1.4 (vs 1.3.1)

The version jump is not cosmetic. If you reuse 1.3.1 commands verbatim they will fail.

- **`--visualization` / `--visualization-only` were removed.** Visualization is now generated **by default** on every run. **There is no flag to skip visualization** in 1.4.0-beta. The only ways to make a run cheaper are `--skip-cellprofiler` (drops morphology features) and/or subsetting with `--tile` / `--well` / `--batch`.
- **Visualization output is now a SpatialData object.** A `SpatialData/` subdirectory holds the zipped Spatial Data Object (`<RunName>.zarr.zip`), the global shape tables (`cell_shapes_global.parquet`, `nuclear_shapes_global.parquet`), a zarr index (`<RunName>.zarr-index.json.gz`), and the **`cyto.viz` manifest** (inside `SpatialData/`, not the top level). Stats files and the MultiQC report stay at the top level of `OUT_DIR`. Runs that contain points data additionally emit points outputs (and a `cyto.zip`); point-free runs skip these. Output is compatible with CytoCanvas Studio and CytoCanvas ≥ 1.4.9.
- **The viz Python stack moved to Python 3.11**, and `cells2stats` defaults `--python` to `/usr/bin/python3` (bare 3.10). The wrapper therefore passes `--python /usr/bin/python3.11`; without it, visualization fails with `ModuleNotFoundError: No module named 'zarr'`.
- **`spatialdata` needs a writable Numba cache.** The wrapper sets `NUMBA_CACHE_DIR` to the lscratch-backed `/tmp`; without it, viz fails with `no locator available for file ... datashader ...` (see [Troubleshooting](#visualization-fails-with-no-locator-available-for-file--datashader-)).
- **New flags:** `--build-viz-from-SDO`, `--viz-shape-smoothing-workers`, `--viz-points-sort-threads`, `--viz-points-sort-memory-gb` (plus some OPS flags). See the [argument table](#cells2stats-arguments-most-used-subset).
- **Short-flag changes:** `-r` is now `--output-remote` (was run-manifest), `--run-manifest` is now `-R`, `--input-remote` gained `-i`, `--tca-manifest` is `-M` and now accepts `.json`.
- **MultiQC** bumped to 1.35.

---

## 1. Building the container

The prebuilt image lives at `/data/$USER/containers/cells2stats/cells2stats-full-1.4.0.sif`. Rebuild only when the def file changes or the upstream `elembio/cells2stats:1.4.0-beta` is updated.

> **Note on paths:** on Biowulf, `/data/$USER` is an alias (symlink) for `/vf/users/$USER`. Either path works; container bindpaths handle both transparently. This document uses `/data/$USER` throughout for brevity.

### Prerequisites

- A Biowulf account with `/data/$USER` quota of at least ~15 GB free (the 1.4 image is larger than 1.3.1; SIF + build cache).
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
   singularity build cells2stats-full-1.4.0.sif /data/$USER/cells2stats/defs/cells2stats-1.4.0.def
   ```

   The build pulls the Docker image, installs `bowtie` via apt, and runs the `%test` block. If `%test` fails (missing binary, broken Python import) the build aborts — fix the def file and retry.

   > **Confirm the tag before building.** The published tag carries the `-beta` suffix; `elembio/cells2stats:1.4.0` does **not** exist (`MANIFEST_UNKNOWN`). List published tags with:
   > ```bash
   > curl -s "https://hub.docker.com/v2/repositories/elembio/cells2stats/tags?page_size=100" | grep -o '"name":"[^"]*"'
   > ```

5. Verify:

   ```bash
   singularity exec cells2stats-full-1.4.0.sif cells2stats --version
   singularity exec cells2stats-full-1.4.0.sif /opt/cellprofiler/bin/python3 -c \
       "import cellprofiler; print(cellprofiler.__version__)"
   # Viz stack lives in python3.11. Set NUMBA_CACHE_DIR to a writable dir, or
   # the spatialdata import hits the read-only-rootfs Numba locator error:
   SINGULARITYENV_NUMBA_CACHE_DIR=/tmp \
       singularity exec cells2stats-full-1.4.0.sif /usr/bin/python3.11 -c \
       "import zarr, spatialdata; print('viz OK')"
   ```

### Notes on the def file

- The `%post` block is intentionally minimal — only `bowtie` is added on top of the upstream image. Keep additions there to preserve reproducibility.
- The `%test` block runs at build time and is the contract for what the container guarantees. Add any new dependency check there.
- **Three Python interpreters coexist** — don't mix them:
  - `/usr/bin/python3` → 3.10, **bare** (the default `python3`).
  - `/usr/bin/python3.11` → the **viz + SpatialData** stack (`/usr/local/lib/python3.11/dist-packages`). This is what `--python` must point at.
  - `/opt/cellprofiler/bin/python3` → 3.8, CellProfiler venv.
- The `%test` viz check runs against `python3.11` and sets `NUMBA_CACHE_DIR` to a writable dir, mirroring the runtime condition (read-only rootfs + writable cache). If that line fails, the build aborts — that's intentional.

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
sbatch run_cells2stats_1.4.0.sh RUN_DIR OUT_DIR [extra cells2stats args...]
```

Examples (using the repo's own `runs/` and `outputs/` directories for input/output):

```bash
# Standard run — CellProfiler + visualization (viz is automatic in 1.4)
sbatch run_cells2stats_1.4.0.sh \
    /data/$USER/cells2stats/runs/20260522_AV254504_Fixed_Slide_Test \
    /data/$USER/cells2stats/outputs/20260522_AV254504_Fixed_Slide_Test

# With target cell assignment (TCA) manifest
sbatch run_cells2stats_1.4.0.sh \
    /data/$USER/cells2stats/runs/<RUN_NAME> \
    /data/$USER/cells2stats/outputs/<RUN_NAME> \
    --tca-manifest /data/$USER/manifests/tca.csv

# Skip CellProfiler — no morphology features; visualization still runs
sbatch run_cells2stats_1.4.0.sh \
    /data/$USER/cells2stats/runs/<RUN_NAME> \
    /data/$USER/cells2stats/outputs/<RUN_NAME> \
    --skip-cellprofiler
```

The wrapper resolves both paths with `readlink -f`, validates `RUN_DIR` exists, creates `OUT_DIR`, and forwards everything after the first two arguments verbatim to `cells2stats`.

> **Regenerating visualization from an existing SDO** (the 1.4 replacement for the old "rerun with `--visualization-only`" salvage) does **not** go through this wrapper, because `--build-viz-from-SDO` disallows a `RUN_DIRECTORY`. Run it directly:
> ```bash
> module load singularity
> . /usr/local/current/singularity/app_conf/sing_binds
> SINGULARITYENV_NUMBA_CACHE_DIR=/tmp \
>   singularity exec /data/$USER/containers/cells2stats/cells2stats-full-1.4.0.sif \
>   cells2stats --python /usr/bin/python3.11 \
>   --build-viz-from-SDO /path/to/RunID.zarr.zip -o /path/to/out
> ```

### Outputs

Confirmed layout from a 1.4.0 run (`OUT_DIR`):

```
OUT_DIR/
├── RunStats.json
├── RawCellStats.csv
├── RawCellStats.parquet
├── AverageNormWellStats.csv
├── AntibodyScreenKitReport.csv         # Teton Custom Screen runs
├── RunManifest.csv
├── RunManifest.json
├── RunParameters.json
├── Panel.json
├── Versions.json                       # component versions for this run
├── multiqc_report.html
├── multiqc_data/                        # MultiQC raw tables + multiqc.parquet
├── CellSegmentation/
│   └── Well<W>/
│       ├── L#R##C##S#_Cell.tif          # per-tile cell mask
│       └── L#R##C##S#_Nuclear.tif       # per-tile nuclear mask
├── Wells/                               # (empty for this run type)
├── Logs/
│   ├── Cells2Stats.log
│   ├── BuildSpatialData.log
│   ├── Visualization.log
│   ├── MultiQCWrapper.log
│   ├── AntibodyScreenKitReportScriptLog.log
│   └── RunManifestErrors.json
└── SpatialData/
    ├── <RunName>.zarr.zip               # the Spatial Data Object (SDO)
    ├── <RunName>.zarr-index.json.gz     # zarr index
    ├── cell_shapes_global.parquet
    ├── nuclear_shapes_global.parquet
    └── cyto.viz                         # CytoCanvas manifest
```

Runs with points data (e.g. OPS) additionally emit points outputs and a `cyto.zip` under `SpatialData/`; the point-free CellPaint run above skipped them. The per-stage logs under `Logs/` (especially `BuildSpatialData.log` and `Visualization.log`) are the first place to look when viz output is incomplete. Point CytoCanvas at the SDO (`SpatialData/<RunName>.zarr.zip`) or the `cyto.viz` manifest.

### What the wrapper does for you

- Loads the `singularity` module (unversioned, per Biowulf policy — staff retire versioned modules without notice).
- Sources `/usr/local/current/singularity/app_conf/sing_binds` so GPFS-backed paths (`/data`, `/vf`, `/fdb`, etc.) are visible inside the container via Biowulf staff-maintained bindpaths.
- Adds `/lscratch/$SLURM_JOB_ID → /tmp` so cells2stats' temporary files land on fast local SSD instead of GPFS.
- Sets `TMPDIR=/tmp` inside the container.
- **Sets `--python /usr/bin/python3.11`** so visualization finds the viz/SpatialData stack (the cells2stats default `/usr/bin/python3` is the bare 3.10 and would fail).
- **Sets `NUMBA_CACHE_DIR=/tmp/numba_cache`** (lscratch-backed) so `spatialdata`/`datashader` Numba JIT caching has a writable location inside the read-only SIF (see [Troubleshooting](#visualization-fails-with-no-locator-available-for-file--datashader-)).
- Pins all BLAS/OMP thread counts to 1, and caps OpenCV and ITK thread pools the same way (see [Troubleshooting → RLIMIT_NPROC](#runtimeerror-cant-start-new-thread--rlimit_nproc-explosion) and [Troubleshooting → OpenCV thread spawn errors](#opencv-cant-spawn-new-thread-errors-during-visualization)).
- Constrains the per-worker JVM (heap, GC threads, stack) that CellProfiler spawns for Bioformats (see [Troubleshooting → JVM crash dumps](#jvm-crash-dumps-hs_err_pidlog)).
- Passes `--num-threads $SLURM_CPUS_PER_TASK` so cells2stats matches the SLURM allocation.
- Passes `--output $OUT_DIR` from the second positional argument.
- **Rejects** `--output`/`-o`/`--num-threads`/`-j`/`--python`/`-P` if passed as extra args (the wrapper manages them), and rejects the removed `--visualization`/`--visualization-only` flags with a helpful message.
- Captures the cells2stats exit code and prints a start/end banner with job ID, node, allocation, viz python, Numba cache dir, and Singularity version for post-mortem.

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

### SLURM resources (edit at the top of `run_cells2stats_1.4.0.sh`)

| Directive             | Default        | When to change                                                                       |
| --------------------- | -------------- | ------------------------------------------------------------------------------------ |
| `--partition`         | `norm`         | `quick` for ≤4 h tests; `largemem` if you hit OOM on `norm` (max 247 GB).             |
| `--cpus-per-task`     | 32             | Lower (8–16) for small runs; higher hits diminishing returns. Viz worker/DuckDB counts derive from this. |
| `--mem`               | 128g           | Bump to 247g for large CellProfiler runs with many cells per FOV.                    |
| `--gres=lscratch:100` | 100 GB         | Increase to 200–400 GB for runs with many cycles or large image/SpatialData sets.    |
| `--time`              | 12:00:00       | Visualization is always on in 1.4, so the baseline is the old `--visualization` runtime. Raise further for large multi-cycle runs. |

### cells2stats arguments (most-used subset)

The full, authoritative reference is at **<https://docs.elembio.io/docs/cells2stats/optional-arguments/>** (and `singularity exec $CONTAINER cells2stats --help` for the live, version-specific list). The subset below is what you'll reach for day-to-day on Biowulf.

| Flag (short)                          | Effect                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------ |
| `--output DIR` (`-o`)                 | Output directory. **Set by the wrapper — don't pass it again.** Default would otherwise be `RUN_DIR/Cytoprofiling/<timestamp>`. |
| `--num-threads N` (`-j`)              | Parallel workers. **Set by the wrapper from `$SLURM_CPUS_PER_TASK`** — don't pass it again. |
| `--python PATH` (`-P`)                | Python used for the visualization script. **Set by the wrapper to `/usr/bin/python3.11`** — don't pass it again. The cells2stats default (`/usr/bin/python3`) lacks the viz stack. |
| `--skip-cellprofiler` (`-s`)          | Run without CellProfiler. Morphology features will not appear in `RawCellStats.csv`/`.parquet`. Visualization still runs. |
| `--skip-html-report` (`-H`)           | Skip MultiQC HTML report generation.                                                       |
| `--build-viz-from-SDO PATH`           | Regenerate visualization from an existing Spatial Data Object zip (`RunID.zarr.zip`). **Disallows a RUN_DIRECTORY**, so run it directly, not via the wrapper (see [§2](#submitting)). |
| `--viz-shape-smoothing-workers N`     | Shape-smoothing worker count for the viz build. Default: derived from `--num-threads`. Lower it if the viz stage throws thread-spawn errors. |
| `--viz-points-sort-threads N`         | DuckDB points-sort thread count for the viz build. Default: derived from `--num-threads`.   |
| `--viz-points-sort-memory-gb N`       | DuckDB memory limit (GB) for the points sort. Default: 16.                                  |
| `--tca-manifest FILE` (`-M`)          | Target cell assignment manifest. `.csv` or `.json`.                                         |
| `--run-manifest FILE` (`-R`)          | Corrected run manifest (`.csv`/`.json`) instead of the instrument's. **Short flag is `-R` in 1.4** (was `-r`). See Element's [Run Manifest docs](https://docs.elembio.io/docs/run-manifest/#corrected-run-manifest). |
| `--panel FILE.json` (`-p`)            | Use an alternate `panel.json` instead of the instrument-emitted one.                        |
| `--segmentation DIR` (`-S`)           | Directory of alternative cell segmentation masks. See Element's [resegmentation tutorial](https://docs.elembio.io/docs/tutorials/cytoprofiling/resegmentation/). |
| `--batch B1,B2,...` (`-b`)            | Restrict analysis to specific batches. Valid: `B1`–`B8`.                                    |
| `--well A1,B2,...` (`-w`)             | Restrict to specific wells. 12-well: `A1`–`F2`; 48-well: `A1`–`L4`.                          |
| `--tile 'REGEX'` (`-t`)               | Restrict to tiles matching a regex (e.g. `'L1R..C..S.'` for all of Lane 1). Repeatable.    |
| `--max-unassigned N` (`-u`)           | Max number of unassigned sequences reported (1–10000, default 30).                          |
| `--log-level LEVEL` (`-l`)            | `info` (default), `debug`, `warning`, `error`. Use `debug` when filing bug reports.         |
| `--error-on-missing` (`-m`)           | Fail on missing input files instead of skipping them.                                       |
| `--no-error-on-invalid` (`-n`)        | Skip invalid files and continue (the default is also to skip; this is the explicit form).   |
| `--verbose-transfer` (`-T`)           | Print filenames during remote log/file transfer.                                            |

OPS-specific flags also exist (`--generate-specialized-targeted-bams`, `--specialized-targeted-min-query-length N`, `--target-mismatch-threshold N`); see `--help`.

> **Don't pass these from the command line on Biowulf** — the container provides them and the defaults are correct: `--bases2fastq`, `--bowtie`, `--bowtie-build`, `--cellprofiler`, `--samtools`. These flags exist for non-containerized installs that need to point at host binaries. (`--python` is also container-provided, but the wrapper sets it explicitly to `python3.11`; don't pass it yourself.)

The `--input-remote` / `--output-remote` rclone flags also aren't relevant on Biowulf — keep data on `/data` (= `/vf/users`) and let the bindpath handle it.

---

## 4. Troubleshooting

### Container not found

```
Container not found: /data/$USER/containers/cells2stats/cells2stats-full-1.4.0.sif
```

You're running someone else's submission, or you haven't built it yet. The wrapper resolves `$USER` per-submitter. Either build your own copy (Section 1) or edit `CONTAINER=` in the wrapper to point at a shared lab build.

### `ERROR: '--visualization' was removed in cells2stats 1.4`

You carried over a 1.3.1 command. `--visualization`/`-V` and `--visualization-only`/`-O` no longer exist; visualization runs by default. Drop the flag. To regenerate viz from an existing SDO, use `--build-viz-from-SDO` directly (see [§2](#submitting)).

### Visualization fails with `ModuleNotFoundError: No module named 'zarr'`

The viz Python stack is in `/usr/bin/python3.11`, but cells2stats defaults `--python` to `/usr/bin/python3` (bare 3.10). The wrapper passes `--python /usr/bin/python3.11`; if you're invoking cells2stats **manually**, add that flag. To confirm the stack is present:

```bash
SINGULARITYENV_NUMBA_CACHE_DIR=/tmp \
    singularity exec $CONTAINER /usr/bin/python3.11 -c "import zarr, spatialdata; print('ok')"
```

### Visualization fails with `no locator available for file ... datashader ...`

`spatialdata` (new in 1.4) pulls in `datashader`, which JIT-compiles with Numba `@njit(cache=True)`. Numba's default cache location is next to the source file in `dist-packages`, which is **read-only** inside the SIF, so the import aborts. The wrapper sets `NUMBA_CACHE_DIR=/tmp/numba_cache` (lscratch-backed and writable). If invoking manually, set `SINGULARITYENV_NUMBA_CACHE_DIR` to any writable path. This is a Docker→Singularity porting artifact: in Docker the package dir is writable, so it never surfaces.

### `RUN_DIR not found`

The wrapper calls `readlink -f` before validating. If the path is on `/vf/users/...` and you submitted from a node that hasn't refreshed the automount, the path may briefly fail. `cd` into the directory once from the submit host before resubmitting.

### Job dies immediately with `singularity: command not found`

The wrapper runs `module load singularity` (unversioned, per Biowulf policy). If `module` itself isn't found, your shell environment is wiping `MODULEPATH` — submit from a clean login shell.

If the Singularity default has just been bumped on Biowulf and the SIF misbehaves with the new version (rare but possible), rebuild the SIF against the current default to confirm compatibility before debugging further.

### `ERROR: do not pass '--output' as an extra argument`

You passed `--output`/`-o`, `--num-threads`/`-j`, or `--python`/`-P` in the extra-args position. The wrapper manages these — drop them from your `sbatch` command line.

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
...
Failed to handle cell border calculation for .../WellB1/L2R06C01S1_Cell.tif with error can't start new thread
...
```

`res = 11` is errno `EAGAIN` from `pthread_create` — the per-user thread/process ceiling (`RLIMIT_NPROC=1024`) has been hit. **OpenCV** (`cv2`, still present in the 1.4 viz python) does NOT honor `OMP_NUM_THREADS` unless built with OpenMP — which the upstream image is not. cv2 queries the host CPU count (192 on Biowulf EPYC 9454 nodes) and tries to spin up that many threads per `cv2.parallel_for_` region.

> **Note for 1.4:** cells2stats now self-manages viz parallelism — it clamps the SpatialData/visualization workers to roughly `--num-threads / 3` and sets its own library thread caps (e.g. `POLARS_MAX_THREADS`, `OMP/OPENBLAS/MKL/NUMEXPR_NUM_THREADS=3`) for those subprocesses. In practice the 1.3.1 explosion no longer reproduces with the default allocation. The wrapper's pins below remain as defense-in-depth and are harmless.

**Fix (already in this wrapper):**

```
SINGULARITYENV_OPENCV_FOR_THREADS_NUM=1
SINGULARITYENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
```

In 1.4 you have an additional lever specific to the new viz pipeline: lower `--viz-shape-smoothing-workers` and `--viz-points-sort-threads` (they otherwise derive from `--num-threads`). After applying fixes, verify:

```bash
grep -c "Can't spawn new thread" scripts/logs/c2s_<JOBID>.out          # should be 0
grep -c "Failed to handle cell border" scripts/logs/c2s_<JOBID>.out    # should be 0
```

**The job may exit 0 with incomplete viz output** — affected tiles are silently skipped. If a prior run was affected, regenerate viz from the SDO with `--build-viz-from-SDO` (see [§2](#submitting)) rather than re-running the whole pipeline.

### DuckDB out-of-memory during the points sort

The 1.4 viz build sorts points with DuckDB, default memory limit 16 GB (`--viz-points-sort-memory-gb`). On large runs this can OOM independently of the SLURM `--mem` allocation. Raise it (e.g. `--viz-points-sort-memory-gb 32`) and/or lower `--viz-points-sort-threads`. Make sure the SLURM `--mem` covers it.

### Out of disk space mid-run

cells2stats writes a lot of intermediate data to `$TMPDIR`, and 1.4 additionally stages SpatialData output. The wrapper binds `/lscratch/$JOBID` (sized by `--gres=lscratch:N`) to `/tmp`. If you see `No space left on device`, increase `--gres=lscratch:` (allowed up to 800 GB on most `norm` nodes; check `freen`).

### Out of memory (OOM) — job killed by SLURM

Symptom in `scripts/logs/c2s_<JOBID>.err`:

```
slurmstepd: error: Detected 1 oom-kill event(s)
```

Options, in order of preference:

1. Raise `--mem` (up to 247g on `norm`).
2. Lower `--cpus-per-task` — fewer parallel workers = less peak memory.
3. Switch to `--partition=largemem` and request more.
4. If the OOM is in the viz points sort specifically, see [DuckDB OOM](#duckdb-out-of-memory-during-the-points-sort) above.

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

**The most likely cause is *not* a Java OOM.** A crash during `G1CollectedHeap::initialize` / `AbstractWorkGang::add_workers`, with elapsed time under a second, is the JVM dying while spawning its GC worker threads — the per-user thread/process limit (`RLIMIT_NPROC=1024`), not heap. The JVM auto-sizes its GC thread pool from the *host* CPU count (192 on the AMD EPYC 9454 nodes), not from `$SLURM_CPUS_PER_TASK`.

**Fix (already in this wrapper):**

```
SINGULARITYENV_JAVA_TOOL_OPTIONS="-Xmx4g -Xms512m -XX:ParallelGCThreads=2 -XX:ConcGCThreads=1 -XX:CICompilerCount=2 -Xss512k"
```

To confirm the flags reach the JVM, look near the start of `c2s_<JOBID>.out` for:

```
Picked up JAVA_TOOL_OPTIONS: -Xmx4g -Xms512m -XX:ParallelGCThreads=2 ...
```

If that line is missing, the env var isn't crossing the Singularity boundary — verify the `SINGULARITYENV_` prefix is intact.

**Other causes (less common):** an actual Java heap OOM (stack says `java.lang.OutOfMemoryError: Java heap space`; raise `-Xmx` to `8g`); a corrupt/truncated TIFF crashing the Bioformats reader (look for a file path near the top of the dump); or a genuine SLURM-side OOM (whole job killed by `slurmstepd`). The dump files are harmless artifacts; safe to delete after diagnosis. Add `scripts/hs_err_pid*.log` and `scripts/core.*` to `.gitignore`.

### Build fails at `%test`

A test command exited non-zero. Read the build log carefully. Common cases:
- A viz import fails in `python3.11` — the upstream image dropped or relocated a package. The `%test` prints a per-module `OK`/`FAIL` list naming the culprit.
- `spatialdata` fails with the Numba locator error — `NUMBA_CACHE_DIR` isn't set in `%test` (it should be; see the def).
- `apt-get` failing because the package list expired (`%post` rebuilds it; re-run the build).

### Slow visualization output

Visualization is always on in 1.4 and writes SpatialData output to `OUT_DIR`. If `OUT_DIR` is on `/data` (GPFS), it will be slower than `/lscratch`. For very large viz outputs, write to `/lscratch/$JOBID/out` and `rsync` the result to `/data` at the end of the script.

### Diagnosing with `--log-level debug`

When opening a support thread or filing a bug, rerun the failing job with `--log-level debug` appended to the `sbatch` arguments. The verbose log goes to `scripts/logs/c2s_<JOBID>.out` alongside the cells2stats internal log inside `OUT_DIR`.

---

## Legacy 1.3.1

The 1.3.1 artifacts are retained and unchanged:

- def: `defs/cells2stats-full.def`
- wrapper: `scripts/run_cells2stats.sh` (points at `cells2stats-full.sif`)
- SIF: `/data/$USER/containers/cells2stats/cells2stats-full.sif`

Use them only to reproduce older results. New runs should use the 1.4.0 path above. Note that 1.3.1 and 1.4.0 produce **different visualization output formats** (1.3.1 emits the old CytoCanvas viz folder; 1.4.0 emits a SpatialData object compatible with CytoCanvas ≥ 1.4.9), so don't mix outputs across versions.

---

## References

- cells2stats documentation: <https://docs.elembio.io/docs/cells2stats/introduction/>
- All optional arguments: <https://docs.elembio.io/docs/cells2stats/optional-arguments/>
- Release notes: <https://docs.elembio.io/docs/cells2stats/c2s-release-notes/>
- Biowulf Singularity guide: <https://hpc.nih.gov/apps/singularity.html>

## Contact

HiTIF — Gianluca Pegoraro. Open an issue in this repo for bugs or improvement requests.
