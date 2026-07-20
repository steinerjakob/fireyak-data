#!/usr/bin/env bash
#
# FireYak data pipeline
# 1. Download planet (first run) / apply daily diffs (subsequent runs)
# 2. Filter fire-fighting water sources
# 3. Export to FlatGeobuf + PMTiles
# 4. Upload to a rolling GitHub Release
#
# Required env:
#   GITHUB_TOKEN   - fine-grained PAT with "contents: read/write" on the data repo
#   GITHUB_REPO    - e.g. "steinerjakob/fireyak-data"
# Optional env:
#   PLANET_URL     - default: planet.osm.org latest
#   RELEASE_TAG    - default: "latest"
#   SKIP_UPLOAD=1  - build only, no upload (for benchmarking)

set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
PLANET="${DATA_DIR}/planet.osm.pbf"
PLANET_URL="${PLANET_URL:-https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
WORK="${DATA_DIR}/work"
OUT="${DATA_DIR}/out"
LOCK="${DATA_DIR}/.pipeline.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------- lock
if [ -e "$LOCK" ]; then
    log "Lock file exists ($LOCK) - previous run still active or crashed. Aborting."
    exit 1
fi
trap 'rm -f "$LOCK"' EXIT
touch "$LOCK"

mkdir -p "$WORK" "$OUT"

# ------------------------------------------------- 1. planet download / update
if [ ! -f "$PLANET" ]; then
    log "No planet file found - initial download (~80 GB, this takes a while)..."
    curl -fL --retry 5 --retry-delay 30 -C - -o "${PLANET}.part" "$PLANET_URL"
    mv "${PLANET}.part" "$PLANET"
    log "Planet download complete."
else
    log "Applying replication diffs to planet file..."
    # rewrites the planet file; needs ~80 GB free scratch space on the same volume
    pyosmium-up-to-date --size 20000 -v "$PLANET" || {
        rc=$?
        # exit code 1 = still not fully up to date (more diffs than --size allows) - fine
        if [ "$rc" -gt 1 ]; then
            log "pyosmium-up-to-date failed with exit code $rc"
            exit "$rc"
        fi
    }
    log "Planet update complete."
fi

# ------------------------------------------------- 2. filter water sources
FILTERED="${WORK}/water_sources.osm.pbf"
log "Filtering fire-fighting water sources from planet (1.5-4 h on a DS423+)..."
osmium tags-filter "$PLANET" \
    nwr/emergency=fire_hydrant \
    nwr/emergency=water_tank \
    nwr/emergency=suction_point \
    nwr/emergency=fire_water_pond \
    nwr/amenity=fire_station \
    --overwrite -o "$FILTERED"
log "Filter complete: $(du -h "$FILTERED" | cut -f1)"

# ------------------------------------------------- 3. export geometries
GEOJSONSEQ="${WORK}/water_sources.geojsonseq"
log "Exporting to GeoJSONSeq..."
osmium export "$FILTERED" \
    -c /etc/osmium-export-config.json \
    -f geojsonseq \
    --overwrite -o "$GEOJSONSEQ"

# ------------------------------------------------- 4a. FlatGeobuf (bbox queries / nearby search)
FGB="${OUT}/water_sources.fgb"
log "Building FlatGeobuf..."
ogr2ogr -f FlatGeobuf "$FGB" "$GEOJSONSEQ" \
    -nlt GEOMETRY \
    -nln water_sources \
    --config OGR_GEOJSON_MAX_OBJ_SIZE 0

# ------------------------------------------------- 4b. PMTiles (map display)
PMT="${OUT}/water_sources.pmtiles"
log "Building PMTiles with tippecanoe..."
tippecanoe -o "$PMT" \
    -l water_sources \
    -Z4 -z14 -B10 \
    --drop-densest-as-needed \
    --extend-zooms-if-still-dropping \
    --force \
    "$GEOJSONSEQ"

# ------------------------------------------------- 5. metadata
META="${OUT}/metadata.json"
FEATURES=$(osmium fileinfo -e -g data.count.nodes "$FILTERED" 2>/dev/null || echo "n/a")
cat > "$META" <<EOF
{
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "source": "OpenStreetMap (ODbL) - https://www.openstreetmap.org/copyright",
  "planet_timestamp": "$(osmium fileinfo -e -g header.option.timestamp "$PLANET" 2>/dev/null || echo unknown)",
  "filters": ["emergency=fire_hydrant","emergency=water_tank","emergency=suction_point","emergency=fire_water_pond","amenity=fire_station"]
}
EOF

log "Outputs:"
ls -lh "$OUT"

# ------------------------------------------------- 6. upload to rolling release
if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    log "SKIP_UPLOAD set - done without uploading."
    exit 0
fi

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
export GH_TOKEN="$GITHUB_TOKEN"

log "Uploading to GitHub release '$RELEASE_TAG' in $GITHUB_REPO..."
if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" --repo "$GITHUB_REPO" \
        --title "Latest water source data" \
        --notes "Rolling release, updated automatically. Data (c) OpenStreetMap contributors, ODbL."
fi
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPO" --clobber \
    "$FGB" "$PMT" "$META"

# keep the release timestamp fresh so consumers can check recency
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPO" \
    --notes "Updated: $(date -u '+%Y-%m-%d %H:%M UTC'). Data (c) OpenStreetMap contributors, ODbL."

log "Upload complete. Done."
