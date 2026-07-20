# FireYak Data Pipeline

Self-published static OpenStreetMap extracts of fire-fighting infrastructure, built on a schedule and served as static files.

The pipeline filters the OSM planet file down to five feature types, converts them to formats that support HTTP range requests, and publishes them to a rolling GitHub Release. Consumers read only the bytes they need for a given bounding box — no API server, no rate limits.

Data © OpenStreetMap contributors, licensed under [ODbL](https://www.openstreetmap.org/copyright).

## What gets extracted

| Tag | Geometry |
|---|---|
| `emergency=fire_hydrant` | point |
| `emergency=suction_point` | point |
| `emergency=water_tank` | point / area |
| `emergency=fire_water_pond` | point / area |
| `amenity=fire_station` | point / area |

All original OSM tags are preserved, plus `@id` (`node/123`, `way/456`), `@version`, and `@timestamp`.

## Outputs

| File | Format | Use case |
|---|---|---|
| `water_sources.fgb` | [FlatGeobuf](https://flatgeobuf.org/) | spatially indexed bbox queries via range requests |
| `water_sources.pmtiles` | [PMTiles](https://docs.protomaps.com/pmtiles/) | vector tiles for map rendering (z4–z14) |
| `metadata.json` | JSON | build time, planet timestamp, applied filters |

Published to the `latest` release tag. Assets are replaced in place (`gh release upload --clobber`), so the download URLs stay stable across rebuilds:

```
https://github.com/<owner>/<repo>/releases/download/latest/water_sources.fgb
https://github.com/<owner>/<repo>/releases/download/latest/water_sources.pmtiles
https://github.com/<owner>/<repo>/releases/download/latest/metadata.json
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
              gh release upload --clobber
```

A lock file guards against overlapping runs. If a run fails, the previous release stays live — consumers just see slightly older data.

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
| `GITHUB_TOKEN` | for upload | — |
| `GITHUB_REPO` | for upload | — |
| `SKIP_UPLOAD` | no | `0` |
| `PLANET_URL` | no | planet.openstreetmap.org latest |
| `RELEASE_TAG` | no | `latest` |
| `DATA_DIR` | no | `/data` |

`GITHUB_TOKEN` should be a fine-grained PAT scoped to this repository with **Contents: read and write**. Keep it in an env file outside version control (`chmod 600`) — token expiry is the most likely cause of a silent failure, so set a calendar reminder.

### Scheduling

Any cron-like scheduler works — the container is stateless apart from the mounted volume. On modest hardware a full run takes several hours (diff-apply and filtering dominate), so an overnight schedule every day or two is a reasonable cadence. On constrained hosts, `--cpus` and `--cpu-shares` keep the machine responsive during a run.

## Consuming the data

```bash
npm install flatgeobuf pmtiles
```

```ts
import { deserialize } from 'flatgeobuf/lib/mjs/geojson';

const FGB = 'https://github.com/<owner>/<repo>/releases/download/latest/water_sources.fgb';

for await (const feature of deserialize(FGB, { minX, minY, maxX, maxY })) {
  // GeoJSON feature with all OSM tags + @id / @version / @timestamp
}
```

FlatGeobuf's spatial index means only the relevant chunks are fetched. These are plain HTTPS range requests against GitHub's CDN, so they work from browsers and mobile runtimes without special transports.

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

- `Dockerfile` — osmium-tool, pyosmium, GDAL, tippecanoe, GitHub CLI
- `build.sh` — the pipeline
- `export-config.json` — osmium export attributes and area-tag rules
