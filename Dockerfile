# FireYak data pipeline
# osmium-tool + pyosmium (planet updates) + GDAL (FlatGeobuf) + tippecanoe (PMTiles) + gh (upload)
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        osmium-tool \
        pyosmium \
        gdal-bin \
        curl \
        ca-certificates \
        git \
        build-essential \
        libsqlite3-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# tippecanoe (not packaged in Debian) - build from source
RUN git clone --depth 1 https://github.com/felt/tippecanoe.git /tmp/tippecanoe \
    && make -C /tmp/tippecanoe -j"$(nproc)" \
    && make -C /tmp/tippecanoe install \
    && rm -rf /tmp/tippecanoe

# rclone for uploading to Cloudflare R2 (S3-compatible)
RUN curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.deb \
        -o /tmp/rclone.deb \
    && apt-get update && apt-get install -y /tmp/rclone.deb \
    && rm -f /tmp/rclone.deb \
    && rm -rf /var/lib/apt/lists/*

COPY build.sh /usr/local/bin/build.sh
COPY export-config.json /etc/osmium-export-config.json
RUN chmod +x /usr/local/bin/build.sh

WORKDIR /data
ENTRYPOINT ["/usr/local/bin/build.sh"]