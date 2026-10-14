# Fangs: Community Edition — server image: replacement backend + headless game hosts (Wine).
# Game files are NOT part of the image; mount your FANGS install at /game (read-only).
FROM debian:trixie-slim

# UE4SS v3.0.1-1170-g9e7fed53 (experimental build; the "experimental-latest" release it came from is a
# moving target, so the zip is shipped with the build: deploy.sh puts it at server/ue4ss.zip)
ARG UE4SS_SHA256=c07a0ece72ccb381a3ca97b602071fe919eb6def052f4ff183ffc524d8b18933

# Wine from WineHQ, pinned: Debian's own Wine 10.0 crashed the game servers (exit 3) on map changes and at
# random shortly after start; 11.18 is the version the whole flow is tested with.
ARG WINE_VERSION=11.18~trixie-1
ARG WINEHQ_KEY_FPR=D43F640145369C51D786DDEA76F1A20FF987672F
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -d -m 755 /etc/apt/keyrings \
 && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key -o /tmp/winehq.key \
 && gpg --show-keys --with-colons /tmp/winehq.key | grep -q "^fpr:::::::::$WINEHQ_KEY_FPR:" \
 && gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key /tmp/winehq.key && rm /tmp/winehq.key \
 && curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources \
      -o /etc/apt/sources.list.d/winehq-trixie.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      winehq-devel=$WINE_VERSION wine-devel=$WINE_VERSION wine-devel-amd64=$WINE_VERSION wine-devel-i386:i386=$WINE_VERSION \
      libfreetype6 libfontconfig1 libgnutls30 libdbus-1-3 libxrandr2 libxrender1 libxi6 libxcursor1 \
      libxcomposite1 libxinerama1 libxfixes3 libxxf86vm1 \
      xvfb xauth python3 python3-aiohttp unzip procps \
 && apt-get purge -y gnupg && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
 && wine --version

WORKDIR /opt/fangs
COPY server/ue4ss.zip /tmp/ue4ss.zip
RUN echo "$UE4SS_SHA256  /tmp/ue4ss.zip" | sha256sum -c - \
 && mkdir -p third_party/ue4ss/dist && unzip -q /tmp/ue4ss.zip -d third_party/ue4ss/dist && rm /tmp/ue4ss.zip

COPY backend/fangs_backend.py backend/hosts.py backend/matchmaker.py backend/
COPY backend/seed/make_seed.py backend/seed/augments-*.json backend/seed/cosmetics-*.json backend/seed/levels-*.json backend/seed/
COPY server/run-host.sh server/entrypoint.sh server/
COPY tools/ue4ss tools/ue4ss
COPY tools/run/config tools/run/config
COPY player player

# Unprivileged runtime user; the compose file additionally drops all capabilities and makes the
# root filesystem read-only. The game's 2020-era netcode is the most exposed part, so it runs boxed in.
RUN useradd -m -u 10001 -s /usr/sbin/nologin fangs && mkdir -p /data && chown fangs:fangs /data
USER fangs
ENV HOME=/home/fangs WINEPREFIX=/data/wine FANGS_PREFIX_PER_HOST=1 WINEDEBUG=-all \
    PUBLIC_HOST=127.0.0.1 BACKEND_PORT=8080 QOS_PORT=11032 HOST_PORTS=7777-7778
VOLUME ["/data"]
EXPOSE 8080/tcp 11032/udp 7777-7786/udp
ENTRYPOINT ["/opt/fangs/server/entrypoint.sh"]
