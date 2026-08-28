# Headless-Browser

Unikraft Cloud remote browser node:

- Remote: CloakBrowser + Xvfb + Openbox + x11vnc + noVNC
- Local: OpenCode + agent-browser
- noVNC is published through Unikraft HTTPS service
- CDP stays private and is reached with `kraft cloud tunnel`

## Architecture

```text
Local OpenCode -> local agent-browser -> localhost:9222
                                       -> kraft cloud tunnel
                                       -> private CloakBrowser CDP :9222

Operator browser -> HTTPS noVNC :443 -> websockify :6080
                                      -> x11vnc :5901
                                      -> Xvfb :99
                                      -> same CloakBrowser window
```

## GitHub repository configuration

Create these Actions secrets:

- `UKC_TOKEN` required
- `VNC_PASSWORD` strongly recommended
- `CLOAKSERVE_AUTH_TOKEN` strongly recommended
- `CLOAKBROWSER_LICENSE_KEY` optional

Create these Actions variables:

- `UKC_METRO`, default `fra`
- `UKC_INSTANCE_NAME`, default `cloak-browser`

Run **Actions -> Deploy to Unikraft Cloud -> Run workflow**.

## Local CDP tunnel

Install KraftKit and agent-browser locally, then:

```bash
export UKC_TOKEN='...'
export UKC_METRO='fra'
export UKC_INSTANCE_NAME='cloak-browser'
./scripts/open-tunnel.sh
```

Keep that terminal open. In another terminal:

```bash
agent-browser connect 9222
agent-browser --session opencode-main --pin-tab open https://example.com
agent-browser --session opencode-main snapshot -i
```

## Local container test

```bash
docker build -t headless-browser .
docker run --rm \
  --shm-size=256m \
  -e VNC_PASSWORD='change-me' \
  -p 6080:6080 \
  -p 127.0.0.1:9222:9222 \
  headless-browser
```

Open `http://localhost:6080/vnc.html`. CDP is available at `http://127.0.0.1:9222/json/version`.

## Notes

The Hobby plan does not expose instance shared-memory as a plan feature, so CloakBrowser is launched with `--disable-dev-shm-usage`. Only noVNC is public. Never publish CDP port 9222 directly.

## Hobby image-size strategy

The CloakBrowser Chromium payload is intentionally not embedded in the image.
`cloakserve` downloads and verifies the browser binary on first boot. This keeps
the registry image below the Hobby 1 GiB image-storage limit at the cost of a
longer first start. A persistent volume/cache can be added after the initial
Unikraft runtime validation.
