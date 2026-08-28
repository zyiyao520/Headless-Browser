FROM cloakhq/cloakbrowser:latest

USER root

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      x11vnc \
      novnc \
      websockify \
      x11-utils \
      tini \
      procps \
      netcat-openbsd \
      curl \
      jq \
    && rm -rf /var/lib/apt/lists/*

RUN install -d -m 0755 /data/profile /data/downloads /data/screenshots /data/logs /run/browser-stack

COPY scripts/entrypoint.sh /usr/local/bin/browser-stack-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/browser-stack-healthcheck
RUN chmod 0755 /usr/local/bin/browser-stack-entrypoint /usr/local/bin/browser-stack-healthcheck

ENV DISPLAY=:99 \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    CDP_PORT=9222 \
    CLOAK_IDLE_TIMEOUT=300 \
    CLOAK_DATA_DIR=/data/profile

EXPOSE 6080 9222

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/browser-stack-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/browser-stack-entrypoint"]
