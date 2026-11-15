# FireYak Data Pipeline

Self-published static OpenStreetMap extracts of fire-fighting infrastructure, built on a schedule and served as static files.

The pipeline filters the OSM planet file down to five feature types (plus out-of-service water sources), converts them to formats that support HTTP range requests, and publishes them to a Cloudflare R2 bucket. Consumers read only the bytes they need for a given bounding box — no API server, no rate limits.

Data © OpenStreetMap contributors, licensed under [ODbL](https://www.openstreetmap.org/copyright).

## What gets extracted

| Tag | Geometry |
|---|---|
| `emergency=fire_hydrant` | point |
| `emergency=suction_point` | point |
| `emergency=water_tank` | point / area |
| `emergency=fire_water_pond` | point / area |
| `amenity=fire_station` | point / area |
| `disused:emergency=fire_hydrant` / `suction_point` | point |
| `disused:emergency=water_tank` / `fire_water_pond` | point / area |

The `disused:` rows are out-of-service water sources. The OSM wiki tags them with the lifecycle prefix: `emergency=fire_hydrant` is replaced by `disused:emergency=fire_hydrant`. They are kept so the FireYak app can show them as out of service instead of dropping them.

All original OSM tags are preserved, plus `@id` (`node/123`, `way/456`), `@version`, and `@timestamp`.

## Outputs

| File | Format | Use case |
|---|---|---|
| `water_sources.fgb` | [FlatGeobuf](https://flatgeobuf.org/) | spatially indexed bbox queries via range requests |
| `water_sources.pmtiles` | [PMTiles](https://docs.protomaps.com/pmtiles/) | vector tiles for map rendering (z4–z14) |
| `metadata.json` | JSON | build time, planet timestamp, applied filters |

Written to the root of the R2 bucket and replaced in place on every rebuild, so the URLs stay stable. Each file is uploaded to a temporary key and then moved into place, so readers never see a half-written object; `metadata.json` is uploaded last, after the data files have landed. Served through the bucket's public custom domain:

```
https://data.fireyak.org/water_sources.fgb
https://data.fireyak.org/water_sources.pmtiles
https://data.fireyak.org/metadata.json
```

## How it works

```
planet.osm.pbf ──┬─► first run:  full download (~80 GB)
                 └─► later runs: pyosmium-up-to-date applies replication diffs
                        │
                        ▼
              osmium tags-filter   (five tag selectors)
                        │
                        ▼
              osmium export        (GeoJSONSeq, see export-config.json)
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
     ogr2ogr → .fgb        tippecanoe → .pmtiles
              └─────────┬─────────┘
                        ▼
              rclone upload → Cloudflare R2 → data.fireyak.org
```

A lock file guards against overlapping runs. If a run fails, the previously uploaded objects stay live — consumers just see slightly older data.

## Running it

Everything lives in one Docker image:

```bash
docker build -t fireyak-pipeline .
```

Build only, no upload (useful for the first run or benchmarking):

```bash
docker run --rm -v /path/to/osm-data:/data -e SKIP_UPLOAD=1 fireyak-pipeline
```

Full run with upload:

```bash
docker run --rm -v /path/to/osm-data:/data --env-file /path/to/env fireyak-pipeline
```

The mounted `/data` directory holds `planet.osm.pbf`, a `work/` scratch dir, and the final `out/`. Budget roughly 250 GB — the planet file plus a temporary copy written during the diff-apply step.

### Configuration

| Variable | Required | Default |
|---|---|---|
| `R2_ACCESS_KEY` | for upload | — |
| `R2_SECRET` | for upload | — |
| `R2_ENDPOINT` | for upload | — |
| `R2_BUCKET` | for upload | — |
| `SKIP_UPLOAD` | no | `0` |
| `SKIP_UPDATE` | no | `0` |
| `PLANET_URL` | no | planet.openstreetmap.org latest |
| `DATA_DIR` | no | `/data` |

The R2 credentials come from an R2 API token (**Object Read & Write**, scoped to the target bucket). `R2_ENDPOINT` is `https://<account-id>.r2.cloudflarestorage.com`. Keep them in an env file outside version control (`chmod 600`, and it's in `.gitignore`) — a revoked or expired token is the most likely cause of a silent upload failure.

### Scheduling

Any cron-like scheduler works — the container is stateless apart from the mounted volume. On modest hardware a full run takes several hours (diff-apply and filtering dominate), so an overnight schedule every day or two is a reasonable cadence. On constrained hosts, `--cpus` and `--cpu-shares` keep the machine responsive during a run.

## Consuming the data

```bash
npm install flatgeobuf pmtiles
```

```ts
import { deserialize } from 'flatgeobuf/lib/mjs/geojson';

const FGB = 'https://data.fireyak.org/water_sources.fgb';

for await (const feature of deserialize(FGB, { minX, minY, maxX, maxY })) {
  // GeoJSON feature with all OSM tags + @id / @version / @timestamp
}
```

FlatGeobuf's spatial index means only the relevant chunks are fetched. These are plain HTTPS range requests against R2's CDN, so they work from browsers and mobile runtimes without special transports. Make sure the bucket's CORS policy allows range requests (`GET`, `HEAD`, and the `Range` header) from your app's origin.

If you also query the live OSM API (Overpass or similar) for freshness, merge by `@id` with the higher `@version` winning, and treat features missing from the live response as still present — an incomplete live response is not a deletion.

## Validating a build

```bash
# schema and feature count
ogrinfo -so -al out/water_sources.fgb

# check that ponds came through as polygons
ogrinfo -al out/water_sources.fgb -where "\"emergency\" = 'fire_water_pond'" | head -50

# inspect a tile
tippecanoe-decode out/water_sources.pmtiles 14 8680 5677 | head
```

Then spot-check a hydrant you know against openstreetmap.org.

## Files

- `Dockerfile` — osmium-tool, pyosmium, GDAL, tippecanoe, rclone
- `build.sh` — the pipeline
- `export-config.json` — osmium export attributes and area-tag rules
