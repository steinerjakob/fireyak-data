#!/usr/bin/env bash
#
# FireYak data pipeline
# 1. Download planet (first run) / apply daily diffs (subsequent runs)
# 2. Filter fire-fighting water sources
# 3. Export to FlatGeobuf (spatial-indexed) + PMTiles
# 4. Upload to Cloudflare R2
#
# Required env (for upload):
#   R2_ACCESS_KEY  - R2 API token access key id
#   R2_SECRET      - R2 API token secret
#   R2_ENDPOINT    - https://<accountid>.r2.cloudflarestorage.com
#   R2_BUCKET      - e.g. "fireyak-data"
# Optional env:
#   PLANET_URL     - default: planet.osm.org latest
#   SKIP_UPLOAD=1  - build only, no upload (for benchmarking)
#   SKIP_UPDATE=1  - skip pyosmium diff apply (laptop bootstrap; saves 2x planet space)

set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
PLANET="${DATA_DIR}/planet.osm.pbf"
PLANET_URL="${PLANET_URL:-https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
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
    if [ "${SKIP_UPDATE:-0}" = "1" ]; then
        log "SKIP_UPDATE set - using existing planet file as-is (no diff apply)."
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
log "Building FlatGeobuf (spatial-indexed)..."
ogr2ogr -f FlatGeobuf "$FGB" "$GEOJSONSEQ" \
    -nlt GEOMETRY \
    -nln water_sources \
    -lco SPATIAL_INDEX=YES \
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
FEATURES=$(osmium fileinfo -e -g data.count.nodes "$FILTERED" 2>/dev/null || echo 0)
cat > "$META" <<EOF
{
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "planet_timestamp": "$(osmium fileinfo -e -g header.option.timestamp "$PLANET" 2>/dev/null || echo unknown)",
  "feature_count": ${FEATURES},
  "source": "OpenStreetMap (ODbL) - https://www.openstreetmap.org/copyright",
  "filters": ["emergency=fire_hydrant","emergency=water_tank","emergency=suction_point","emergency=fire_water_pond","amenity=fire_station"]
}
EOF

log "Outputs:"
ls -lh "$OUT"

# ------------------------------------------------- 6. upload to Cloudflare R2
if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    log "SKIP_UPLOAD set - done without uploading."
    exit 0
fi

: "${R2_ACCESS_KEY:?R2_ACCESS_KEY is required}"
: "${R2_SECRET:?R2_SECRET is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"

# configure rclone remote from env (no persistent config file needed)
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_ACL=private   # served via custom domain, not r2.dev ACL

log "Uploading outputs to the root of R2 bucket '$R2_BUCKET'..."
# upload to temp names, then move into place, so readers never see a half-written file.
# metadata.json is last so its freshness signal only flips after the data files land.
for f in water_sources.fgb water_sources.pmtiles metadata.json; do
    rclone copyto "${OUT}/${f}" "r2:${R2_BUCKET}/${f}.tmp" --s3-no-check-bucket
    rclone moveto "r2:${R2_BUCKET}/${f}.tmp" "r2:${R2_BUCKET}/${f}" --s3-no-check-bucket
    log "  uploaded ${f}"
done

log "Upload complete. Done."