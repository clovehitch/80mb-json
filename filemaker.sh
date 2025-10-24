#!/usr/bin/env bash
# SUMMARY:
# - Builds a NetBox-style repo IN THE CURRENT DIRECTORY:
#     netbox/scripts/            small .py files (counts & sizes scale with LEVEL)
#     netbox/reports/            small .py files
#     netbox/export_templates/   small .j2 files
#     netbox/config_contexts/    small .json files
#     data/csv/                  a few large CSV blobs (each <= MAX_SINGLE_MB)
#     data/json/                 a number of JSON blobs (each <= MAX_SINGLE_MB)
# - Guarantees:
#     * No single file exceeds MAX_SINGLE_MB (default 99 MB)
#     * Total repo size stays under TOTAL_BUDGET_MB (default 900 MB) to remain under GitHub’s soft 1 GB limit
# - Use LEVEL=1..4 to scale up counts/sizes while still honoring the caps.
#   Example: LEVEL=3 bash make-netbox-test-repo.sh
#   Override budget: TOTAL_BUDGET_MB=800 bash make-netbox-test-repo.sh

set -euo pipefail

# -------- User-adjustable caps --------
MAX_SINGLE_MB="${MAX_SINGLE_MB:-99}"     # hard cap per file
TOTAL_BUDGET_MB="${TOTAL_BUDGET_MB:-900}" # total repo cap (keep < GitHub soft 1 GB)
SMALL_HEADROOM_MB="${SMALL_HEADROOM_MB:-80}" # reserved for small files & overhead

# -------- Level scaling --------
LEVEL="${LEVEL:-2}"
if ! [[ "$LEVEL" =~ ^[1-4]$ ]]; then
  echo "LEVEL must be 1..4 (got '$LEVEL'). Example: LEVEL=3 $0" >&2
  exit 1
fi

case "$LEVEL" in
  1) COUNT_FACTOR=1; SIZE_PCT=100; CSV_PRESET=(45 17 16); JSON_COUNT_TARGET=12; JSON_MIN=5;  JSON_MAX=15 ;;
  2) COUNT_FACTOR=2; SIZE_PCT=150; CSV_PRESET=(70 30 24); JSON_COUNT_TARGET=18; JSON_MIN=8;  JSON_MAX=22 ;;
  3) COUNT_FACTOR=3; SIZE_PCT=200; CSV_PRESET=(90 40 32); JSON_COUNT_TARGET=24; JSON_MIN=10; JSON_MAX=28 ;;
  4) COUNT_FACTOR=4; SIZE_PCT=250; CSV_PRESET=(99 50 45); JSON_COUNT_TARGET=32; JSON_MIN=12; JSON_MAX=35 ;;
esac

# Enforce single-file cap on presets
for i in "${!CSV_PRESET[@]}"; do
  if (( CSV_PRESET[i] > MAX_SINGLE_MB )); then
    CSV_PRESET[i]="$MAX_SINGLE_MB"
  fi
done
if (( JSON_MAX > MAX_SINGLE_MB )); then JSON_MAX="$MAX_SINGLE_MB"; fi

# -------- Base counts (scaled by LEVEL) --------
SCRIPTS_N=$(( 80  * COUNT_FACTOR ))
REPORTS_N=$(( 20  * COUNT_FACTOR ))
TEMPLATES_N=$(( 30 * COUNT_FACTOR ))
CONTEXTS_N=$(( 150 * COUNT_FACTOR ))

# Small-file size ranges (KiB), scaled by SIZE_PCT
scale_kib () { local base="$1"; echo $(( base * SIZE_PCT / 100 )); }
SCRIPTS_MIN_K=$(scale_kib 2);  SCRIPTS_MAX_K=$(scale_kib 15)
REPORTS_MIN_K=$(scale_kib 2);  REPORTS_MAX_K=$(scale_kib 10)
TEMPLATES_MIN_K=$(scale_kib 2);TEMPLATES_MAX_K=$(scale_kib 10)
CONTEXTS_MIN_K=$(scale_kib 5); CONTEXTS_MAX_K=$(scale_kib 50)

# -------- Helpers --------
rand_range () { local min="$1" max="$2"; echo $(( RANDOM % (max - min + 1) + min )); }

pad_kib () {
  local f="$1" kib="$2" cur tgt
  cur=0
  [[ -f "$f" ]] && cur=$(wc -c <"$f")
  tgt=$(( kib * 1024 ))
  if (( cur < tgt )); then
    dd if=/dev/zero bs=1 count=$((tgt - cur)) status=none >> "$f"
  fi
}

mk_mb () {
  local path="$1" mb="$2"
  # Safety: enforce single-file cap
  if (( mb > MAX_SINGLE_MB )); then mb="$MAX_SINGLE_MB"; fi
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${mb}M" "$path"
  else
    dd if=/dev/zero of="$path" bs=1M count="$mb" status=none
  fi
}

sum_array () { local s=0; for v in "$@"; do s=$((s+v)); done; echo "$s"; }

# -------- Create directories --------
mkdir -p netbox/scripts netbox/reports netbox/export_templates netbox/config_contexts data/csv data/json

# -------- Generate small files (they’re tiny vs budget, but we keep headroom) --------
echo "Generating small files (LEVEL=$LEVEL, SIZE_PCT=${SIZE_PCT}%):"
echo "  scripts=$SCRIPTS_N, reports=$REPORTS_N, templates=$TEMPLATES_N, contexts=$CONTEXTS_N"

for i in $(seq 1 "$SCRIPTS_N"); do
  f="netbox/scripts/script_${i}.py"
  cat > "$f" <<'PY'
#!/usr/bin/env python3
class Script:
    def run(self):
        return {"status": "ok"}
PY
  pad_kib "$f" "$(rand_range "$SCRIPTS_MIN_K" "$SCRIPTS_MAX_K")"
done

for i in $(seq 1 "$REPORTS_N"); do
  f="netbox/reports/report_${i}.py"
  cat > "$f" <<'PY'
def report():
    return {"summary": "ok"}
PY
  pad_kib "$f" "$(rand_range "$REPORTS_MIN_K" "$REPORTS_MAX_K")"
done

for i in $(seq 1 "$TEMPLATES_N"); do
  f="netbox/export_templates/template_${i}.j2"
  cat > "$f" <<'J2'
{% for obj in objects -%}
- {{ obj.name }}
{% endfor %}
J2
  pad_kib "$f" "$(rand_range "$TEMPLATES_MIN_K" "$TEMPLATES_MAX_K")"
done

for i in $(seq 1 "$CONTEXTS_N"); do
  f="netbox/config_contexts/context_${i}.json"
  printf '{ "index": %d, "enabled": true }\n' "$i" > "$f"
  pad_kib "$f" "$(rand_range "$CONTEXTS_MIN_K" "$CONTEXTS_MAX_K")"
done

# -------- Budget planning for large blobs --------
CSV_TOTAL_MB=$(sum_array "${CSV_PRESET[@]}")
if (( CSV_TOTAL_MB >= TOTAL_BUDGET_MB )); then
  echo "Requested CSV sizes (${CSV_PRESET[*]} MB) exceed TOTAL_BUDGET_MB=${TOTAL_BUDGET_MB}." >&2
  echo "Increase TOTAL_BUDGET_MB or reduce LEVEL/MAX_SINGLE_MB." >&2
  exit 1
fi

# Keep room for small files & overhead
REMAINING_MB=$(( TOTAL_BUDGET_MB - CSV_TOTAL_MB - SMALL_HEADROOM_MB ))
if (( REMAINING_MB < 0 )); then REMAINING_MB=0; fi

# Plan JSON blobs within remaining budget (random sizes JSON_MIN..JSON_MAX)
# Stop when either count target hit or budget would be exceeded by next file.
declare -a JSON_SIZES=()
for i in $(seq 1 "$JSON_COUNT_TARGET"); do
  # If we can’t afford at least JSON_MIN, stop.
  if (( REMAINING_MB < JSON_MIN )); then break; fi
  # Pick a size that fits budget
  max_allowed=$JSON_MAX
  if (( max_allowed > REMAINING_MB )); then max_allowed="$REMAINING_MB"; fi
  if (( max_allowed < JSON_MIN )); then break; fi
  sz=$(rand_range "$JSON_MIN" "$max_allowed")
  # Enforce single-file cap (already ≤ MAX_SINGLE_MB via JSON_MAX adjustment)
  if (( sz > MAX_SINGLE_MB )); then sz="$MAX_SINGLE_MB"; fi
  JSON_SIZES+=("$sz")
  REMAINING_MB=$(( REMAINING_MB - sz ))
done

# Final safety check: total <= TOTAL_BUDGET_MB
PLANNED_TOTAL=$(( CSV_TOTAL_MB + SMALL_HEADROOM_MB + $(sum_array "${JSON_SIZES[@]}") ))
if (( PLANNED_TOTAL > TOTAL_BUDGET_MB )); then
  echo "Internal planning error: planned total ${PLANNED_TOTAL} MB > TOTAL_BUDGET_MB=${TOTAL_BUDGET_MB}" >&2
  exit 1
fi

echo "Large-file plan:"
echo "  CSV MB: ${CSV_PRESET[*]}  (sum=${CSV_TOTAL_MB} MB)"
echo "  JSON blobs: count=${#JSON_SIZES[@]}, sizes=(${JSON_SIZES[*]}) MB"
echo "  Reserved headroom for small files & overhead: ${SMALL_HEADROOM_MB} MB"
echo "  Planned total (approx): ${PLANNED_TOTAL} MB (cap ${TOTAL_BUDGET_MB} MB)"

# -------- Create large files --------
# CSVs
mk_mb "data/csv/devices_${CSV_PRESET[0]}MB.csv" "${CSV_PRESET[0]}"
mk_mb "data/csv/links_${CSV_PRESET[1]}MB.csv"   "${CSV_PRESET[1]}"
mk_mb "data/csv/sites_${CSV_PRESET[2]}MB.csv"   "${CSV_PRESET[2]}"

# JSON blobs
idx=1
for mb in "${JSON_SIZES[@]}"; do
  mk_mb "data/json/data_${idx}_${mb}MB.json" "$mb"
  idx=$((idx+1))
done

# -------- README --------
cat > README.md <<'MD'
# Test repo for NetBox Enterprise Data Source (GitHub-safe caps)

This tree mimics a typical structure for NetBox-managed files (scripts, reports, export templates, config contexts) plus large CSV/JSON data.

**Caps enforced by the generator:**
- No single file > 99 MB (default MAX_SINGLE_MB, adjustable).
- Total repo size < 900 MB by default (TOTAL_BUDGET_MB), so it stays below GitHub’s soft 1 GB guidance.

**Tips**
- In NetBox Data Source, set Path to `netbox/` so the `data/` tree is not scanned.
- To stress-test, move some large files under `netbox/` and re-sync (not recommended for production).
MD

# -------- Final report --------
echo
echo "Done. Created NetBox-style repo in: $PWD"
echo "LEVEL=$LEVEL  MAX_SINGLE_MB=${MAX_SINGLE_MB}  TOTAL_BUDGET_MB=${TOTAL_BUDGET_MB}"
echo
echo "Quick checks:"
echo "  find . -maxdepth 3 -type f | wc -l"
echo "  du -sh ."
echo "  ls -lh data/csv | sed 's/^/    /'"
echo "  ls -lh data/json | sed 's/^/    /'"

