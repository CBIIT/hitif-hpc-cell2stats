#!/bin/bash
#SBATCH --job-name=cells2stats
#SBATCH --partition=norm
#SBATCH --cpus-per-task=32
#SBATCH --mem=128g
#SBATCH --gres=lscratch:100
#SBATCH --time=4:00:00
#SBATCH --output=logs/c2s_%j.out
#SBATCH --error=logs/c2s_%j.err
#SBATCH --mail-type=BEGIN,END,FAIL

# =============================================================================
# cells2stats wrapper for Biowulf
#
# IMPORTANT: Submit from the repo directory so the relative `logs/` path
# in --output/--error resolves correctly. Create it before first submission:
#   mkdir -p logs
# (The SLURM controller opens the log files BEFORE this script runs, so
# `mkdir -p logs` here would be too late.)
#
# Usage:
#   sbatch run_cells2stats.sh RUN_DIR OUT_DIR [extra cells2stats args...]
#
# Examples:
#   # Full run (CellProfiler + visualization), no TCA
#   sbatch run_cells2stats.sh /data/$USER/runs/exp01 /data/$USER/out/exp01 \
#          --visualization
#
#   # With TCA
#   sbatch run_cells2stats.sh /data/$USER/runs/exp01 /data/$USER/out/exp01 \
#          --visualization --tca-manifest /data/$USER/manifests/tca.csv
#
#   # Visualization only (fast)
#   sbatch run_cells2stats.sh /data/$USER/runs/exp01 /data/$USER/out/exp01 \
#          --visualization-only
#
#   # Skip CellProfiler for a quick stats-only run
#   sbatch run_cells2stats.sh /data/$USER/runs/exp01 /data/$USER/out/exp01 \
#          --skip-cellprofiler
# =============================================================================

set -euo pipefail

# ---- Argument parsing ------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "Usage: sbatch $0 RUN_DIR OUT_DIR [cells2stats args...]" >&2
    exit 1
fi
RUN_DIR="$1"
OUT_DIR="$2"
shift 2
EXTRA_ARGS=("$@")

# Resolve to absolute paths so the container sees them correctly
RUN_DIR="$(readlink -f "$RUN_DIR")"
OUT_DIR="$(readlink -f "$OUT_DIR")"

[[ -d "$RUN_DIR" ]] || { echo "RUN_DIR not found: $RUN_DIR" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Guard against duplicating wrapper-managed flags. The wrapper sets --output
# and --num-threads; passing them again confuses cells2stats.
for arg in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
    case "$arg" in
        --output|-o|--num-threads|-j)
            echo "ERROR: do not pass '$arg' as an extra argument." >&2
            echo "       The wrapper sets it from SLURM allocation / OUT_DIR." >&2
            exit 2
            ;;
    esac
done

# ---- Container location ----------------------------------------------------
CONTAINER="/data/$USER/containers/cells2stats/cells2stats-full.sif"
[[ -f "$CONTAINER" ]] || { echo "Container not found: $CONTAINER" >&2; exit 1; }

# ---- Environment -----------------------------------------------------------
# Biowulf policy: load `singularity` unversioned so users get the
# staff-maintained default. Do NOT pin a version here — the Biowulf docs
# explicitly disallow it (pinned versions are retired without notice and
# break jobs at submission time).
module load singularity

# Biowulf staff-maintained bindpath setup (handles GPFS symlinks, /data, /fdb, etc.)
. /usr/local/current/singularity/app_conf/sing_binds

# Bind /lscratch to /tmp inside container so cells2stats' temp goes there.
# The "${SINGULARITY_BINDPATH:-}" pattern handles the case where sing_binds
# didn't set it (defensive).
export SINGULARITY_BINDPATH="${SINGULARITY_BINDPATH:-},/lscratch/${SLURM_JOB_ID}:/tmp"

# cells2stats uses $TMPDIR; inside the container /tmp == /lscratch/$JOBID on host
export SINGULARITYENV_TMPDIR=/tmp

# Prevent nested BLAS threading inside per-process workers.
# cells2stats spawns $SLURM_CPUS_PER_TASK Python workers; each one's numpy
# would otherwise try to spawn $SLURM_CPUS_PER_TASK BLAS threads, blowing
# past the per-user RLIMIT_NPROC=1024 process limit.
export SINGULARITYENV_OPENBLAS_NUM_THREADS=1
export SINGULARITYENV_MKL_NUM_THREADS=1
export SINGULARITYENV_OMP_NUM_THREADS=1
export SINGULARITYENV_NUMEXPR_NUM_THREADS=1
export SINGULARITYENV_BLIS_NUM_THREADS=1

# Cap OpenCV's parallel backend. cv2 does NOT honor OMP_NUM_THREADS unless
# built with OpenMP, and queries the host CPU count (192 on Biowulf EPYC
# 9454 nodes) by default. The visualization preprocessing script forks ~32
# Python workers and each one's cv2.parallel_for_ tries to spin up that
# many threads, producing hundreds of:
#   [ERROR] parallel_impl.cpp:244 WorkerThread N: Can't spawn new thread: res = 11
# and silent per-tile failures in cell-border calculation. The job still
# exits 0 but visualization output is incomplete.
export SINGULARITYENV_OPENCV_FOR_THREADS_NUM=1

# Cap ITK's global thread pool too, for the same reason — used by some
# skimage / OME-Zarr code paths.
export SINGULARITYENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1

# Constrain JVM thread pools and heap for CellProfiler's per-worker JVMs.
# CellProfiler spawns one JVM per worker via Bioformats. Each JVM auto-sizes
# its GC thread pool from the host CPU count (e.g. 192 on Biowulf AMD EPYC
# 9454 nodes), not from $SLURM_CPUS_PER_TASK. At high --num-threads, the
# concurrent JVM startups blow past the per-user RLIMIT_NPROC=1024 ceiling
# and fail with: "Cannot create worker GC thread. Out of system resources."
# Capping heap (-Xmx) also keeps Committed_AS predictable on busy nodes.
# If you hit "java.lang.OutOfMemoryError: Java heap space" (distinct error),
# bump -Xmx to 8g.
export SINGULARITYENV_JAVA_TOOL_OPTIONS="-Xmx4g -Xms512m -XX:ParallelGCThreads=2 -XX:ConcGCThreads=1 -XX:CICompilerCount=2 -Xss512k"

# ---- Banner ----------------------------------------------------------------
# Memory may be reported as MEM_PER_NODE or MEM_PER_CPU depending on how
# the job was submitted; fall back gracefully.
MEM_REPORT="${SLURM_MEM_PER_NODE:-${SLURM_MEM_PER_CPU:-unknown} (per-CPU)}"
SINGULARITY_VERSION="$(singularity --version 2>/dev/null || echo 'unknown')"

echo "============================================================"
echo "Job ID:        $SLURM_JOB_ID"
echo "Node:          $SLURMD_NODENAME"
echo "CPUs:          $SLURM_CPUS_PER_TASK"
echo "Mem:           ${MEM_REPORT} MB"
echo "lscratch:      /lscratch/$SLURM_JOB_ID"
echo "Singularity:   $SINGULARITY_VERSION"
echo "Container:     $CONTAINER"
echo "Run dir:       $RUN_DIR"
echo "Output dir:    $OUT_DIR"
# Use [@] (not [*]) and quote each element so display matches actual invocation.
if [[ ${#EXTRA_ARGS[@]} -eq 0 ]]; then
    echo "Extra args:    (none)"
else
    printf 'Extra args:    '
    printf '%q ' "${EXTRA_ARGS[@]}"
    printf '\n'
fi
echo "Start:         $(date)"
echo "============================================================"

# ---- Run -------------------------------------------------------------------
# Disable errexit around the singularity call so we can capture the exit
# code AND still print the end-of-run banner. `set -euo pipefail` at the
# top would otherwise terminate the script on a non-zero return before
# EXIT_CODE=$? ever runs.
set +e
singularity exec "$CONTAINER" cells2stats \
    --num-threads "$SLURM_CPUS_PER_TASK" \
    --output "$OUT_DIR" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
    "$RUN_DIR"
EXIT_CODE=$?
set -e

echo "============================================================"
echo "End:         $(date)"
echo "Exit code:   $EXIT_CODE"
echo "============================================================"
exit $EXIT_CODE
