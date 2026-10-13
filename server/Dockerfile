# Fangs: Community Edition — server image: replacement backend + headless game hosts (Wine).
# Game files are NOT part of the image; mount your FANGS install at /game (read-only).
FROM debian:trixie-slim

# UE4SS v3.0.1-1170-g9e7fed53 (experimental build; the "experimental-latest" release it came from is a
# moving target, so the zip is shipped with the build: deploy.sh puts it at server/ue4ss.zip)
ARG UE4SS_SHA256=c07a0ece72ccb381a3ca97b602071fe919eb6def052f4ff183ffc524d8b18933

RUN apt-get update \
 && apt-get install -y --no-install-recommends wine wine64 xvfb xauth python3 python3-aiohttp \
      ca-certificates curl unzip procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/fangs
COPY server/ue4ss.zip /tmp/ue4ss.zip
RUN echo "$UE4SS_SHA256  /tmp/ue4ss.zip" | sha256sum -c - \
 && mkdir -p third_party/ue4ss/dist && unzip -q /tmp/ue4ss.zip -d third_party/ue4ss/dist && rm /tmp/ue4ss.zip

COPY backend/fangs_backend.py backend/hosts.py backend/
COPY backend/seed/make_seed.py backend/seed/
COPY server/run-host.sh server/entrypoint.sh server/
COPY tools/ue4ss tools/ue4ss
COPY tools/run/config tools/run/config
COPY player player

# Unprivileged runtime user; the compose file additionally drops all capabilities and makes the
# root filesystem read-only. The game's 2020-era netcode is the most exposed part, so it runs boxed in.
RUN useradd -m -u 10001 -s /usr/sbin/nologin fangs && mkdir -p /data && chown fangs:fangs /data
USER fangs
ENV HOME=/home/fangs WINEPREFIX=/data/wine WINEDEBUG=-all \
    PUBLIC_HOST=127.0.0.1 BACKEND_PORT=8080 QOS_PORT=11032 HOST_PORTS=7777-7778
VOLUME ["/data"]
EXPOSE 8080/tcp 11032/udp 7777-7786/udp
ENTRYPOINT ["/opt/fangs/server/entrypoint.sh"]
