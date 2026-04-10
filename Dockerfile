# Custom Jellyfin Docker build for fork with cherry-picked patches.
# Stage 1: Download pre-built jellyfin-web release artifact
# Stage 2: Build jellyfin-server from (patched) source
# Stage 3: Assemble runtime image with ffmpeg

ARG DOTNET_VERSION=10.0
ARG OS_VERSION=trixie
ARG FFMPEG_PACKAGE=jellyfin-ffmpeg7

# ======================== Stage 1: Web UI ========================
FROM debian:${OS_VERSION}-slim AS web

ARG JELLYFIN_VERSION

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Download official jellyfin-web portable release
RUN curl -fSL \
    "https://github.com/jellyfin/jellyfin-web/releases/download/v${JELLYFIN_VERSION}/jellyfin-web_${JELLYFIN_VERSION}_portable.tar.gz" \
    -o /tmp/jellyfin-web.tar.gz \
 && mkdir -p /web \
 && tar -xzf /tmp/jellyfin-web.tar.gz -C /web --strip-components=1 \
 && rm /tmp/jellyfin-web.tar.gz

# ======================== Stage 2: Server ========================
FROM debian:${OS_VERSION}-slim AS server

ARG DOTNET_VERSION
ARG DOTNET_ARCH=x64

WORKDIR /src
COPY . .

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    curl ca-certificates libicu76 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://dot.net/v1/dotnet-install.sh \
    | bash /dev/stdin --channel ${DOTNET_VERSION} --install-dir /usr/local/bin

RUN dotnet publish Jellyfin.Server --arch ${DOTNET_ARCH} --configuration Release \
    --output /server --self-contained \
    -p:DebugSymbols=false -p:DebugType=none

# ======================== Stage 3: Runtime ========================
FROM debian:${OS_VERSION}-slim AS runtime

ARG OS_VERSION
ARG FFMPEG_PACKAGE

ENV HEALTHCHECK_URL=http://localhost:8096/health \
    DEBIAN_FRONTEND="noninteractive" \
    LC_ALL="en_US.UTF-8" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    JELLYFIN_DATA_DIR="/config" \
    JELLYFIN_CACHE_DIR="/cache" \
    JELLYFIN_CONFIG_DIR="/config/config" \
    JELLYFIN_LOG_DIR="/config/log" \
    JELLYFIN_WEB_DIR="/jellyfin/jellyfin-web" \
    JELLYFIN_FFMPEG="/usr/lib/jellyfin-ffmpeg/ffmpeg" \
    MALLOC_TRIM_THRESHOLD_=131072 \
    NVIDIA_VISIBLE_DEVICES="all" \
    NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# Install jellyfin-ffmpeg from official repo + runtime deps
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ca-certificates gnupg curl \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg \
 && cat <<EOF > /etc/apt/sources.list.d/jellyfin.sources
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: ${OS_VERSION}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
    ${FFMPEG_PACKAGE} openssl locales libicu76 libfontconfig1 libfreetype6 libjemalloc2 \
 && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && apt-get remove --yes gnupg \
 && apt-get clean autoclean --yes \
 && apt-get autoremove --yes \
 && rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Link jemalloc
RUN mkdir -p /usr/lib/jellyfin \
 && if [ -f /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ]; then \
      ln -s /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/jellyfin/libjemalloc.so.2; \
    fi
ENV LD_PRELOAD=/usr/lib/jellyfin/libjemalloc.so.2

RUN mkdir -p ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && chmod 777 ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}

COPY --from=server /server /jellyfin
COPY --from=web /web /jellyfin/jellyfin-web

ARG JELLYFIN_VERSION
LABEL "org.opencontainers.image.title"="Jellyfin (custom fork)" \
      "org.opencontainers.image.description"="Jellyfin with cherry-picked patches from redinsch" \
      "org.opencontainers.image.version"="${JELLYFIN_VERSION}" \
      "org.opencontainers.image.source"="https://github.com/redinsch/jellyfin"

EXPOSE 8096
VOLUME ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}
ENTRYPOINT ["/jellyfin/jellyfin"]
HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
    CMD curl --noproxy 'localhost' -Lk -fsS "${HEALTHCHECK_URL}" || exit 1
