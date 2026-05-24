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
mkdir -p logs

# ---- Container location ----------------------------------------------------
CONTAINER="/data/$USER/containers/cells2stats/cells2stats-full.sif"
[[ -f "$CONTAINER" ]] || { echo "Container not found: $CONTAINER" >&2; exit 1; }

# ---- Environment -----------------------------------------------------------
module load singularity

# Biowulf staff-maintained bindpath setup (handles GPFS symlinks, /data, /fdb, etc.)
. /usr/local/current/singularity/app_conf/sing_binds

# Bind /lscratch to /tmp inside container so cells2stats' temp goes there.
# The "${SINGULARITY_BINDPATH:-}" pattern handles the case where sing_binds
# didn't set it (defensive).
export SINGULARITY_BINDPATH="${SINGULARITY_BINDPATH:-},/lscratch/${SLURM_JOB_ID}:/tmp"

# cells2stats uses $TMPDIR; inside the container /tmp == /lscratch/$JOBID on host
export SINGULARITYENV_TMPDIR=/tmp

# ---- Run -------------------------------------------------------------------
echo "============================================================"
echo "Job ID:      $SLURM_JOB_ID"
echo "Node:        $SLURMD_NODENAME"
echo "CPUs:        $SLURM_CPUS_PER_TASK"
echo "Mem:         ${SLURM_MEM_PER_NODE} MB"
echo "lscratch:    /lscratch/$SLURM_JOB_ID"
echo "Container:   $CONTAINER"
echo "Run dir:     $RUN_DIR"
echo "Output dir:  $OUT_DIR"
echo "Extra args:  ${EXTRA_ARGS[*]:-(none)}"
echo "Start:       $(date)"
echo "============================================================"

singularity exec "$CONTAINER" cells2stats \
    --num-threads "$SLURM_CPUS_PER_TASK" \
    --output "$OUT_DIR" \
    "${EXTRA_ARGS[@]}" \
    "$RUN_DIR"

EXIT_CODE=$?
echo "============================================================"
echo "End:         $(date)"
echo "Exit code:   $EXIT_CODE"
echo "============================================================"
exit $EXIT_CODE
