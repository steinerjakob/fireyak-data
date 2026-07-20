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

# GitHub CLI for uploading release assets
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY build.sh /usr/local/bin/build.sh
COPY export-config.json /etc/osmium-export-config.json
RUN chmod +x /usr/local/bin/build.sh

WORKDIR /data
ENTRYPOINT ["/usr/local/bin/build.sh"]
