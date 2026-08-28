FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DISPLAY=:99 \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    CDP_PORT=9222 \
    CLOAK_IDLE_TIMEOUT=300 \
    CLOAK_DATA_DIR=/data/profile

# Minimal headed Chromium + VNC runtime. Avoid the upstream CloakBrowser image,
# which also contains Node, the JS wrapper, examples, and build artifacts.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tini procps x11-utils \
      xvfb x11vnc openbox xdotool \
      libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
      libdbus-1-3 libdrm2 libxkbcommon0 libatspi2.0-0 libxcomposite1 \
      libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
      libcairo2 libasound2 libx11-xcb1 libfontconfig1 libx11-6 \
      libxcb1 libxext6 libxshmfence1 libglib2.0-0 libgtk-3-0 \
      libpangocairo-1.0-0 libcairo-gobject2 libgdk-pixbuf-2.0-0 \
      libxss1 libxtst6 fonts-liberation fonts-noto-color-emoji \
      fonts-wqy-zenhei \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

# Install only the Python wrapper and CDP multiplexer. Do not bake the large
# Chromium payload into the OCI/EroFS image because Hobby registry storage is
# capped at 1 GiB. cloakserve downloads and verifies it on first start.
ARG CLOAKBROWSER_SOURCE_REV=d6bad5de261bedf025280ace1d14e800aee13923
RUN pip install --no-cache-dir 'cloakbrowser[serve]' && \
    curl -fsSL \
      "https://raw.githubusercontent.com/CloakHQ/CloakBrowser/${CLOAKBROWSER_SOURCE_REV}/bin/cloakserve" \
      -o /usr/local/bin/cloakserve && \
    chmod 0755 /usr/local/bin/cloakserve && \
    test -x /usr/local/bin/cloakserve && \
    find /usr/local/lib/python3.12/site-packages -type d \
      \( -name tests -o -name __pycache__ \) -prune -exec rm -rf '{}' + && \
    rm -rf /root/.cache /tmp/*

RUN install -d -m 0755 /data/profile /data/downloads /data/screenshots /data/logs /run/browser-stack

COPY scripts/entrypoint.sh /usr/local/bin/browser-stack-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/browser-stack-healthcheck
COPY scripts/novnc_proxy.py /usr/local/bin/novnc-proxy
RUN chmod 0755 /usr/local/bin/browser-stack-entrypoint /usr/local/bin/browser-stack-healthcheck /usr/local/bin/novnc-proxy

EXPOSE 6080 9222

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/browser-stack-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/browser-stack-entrypoint"]
