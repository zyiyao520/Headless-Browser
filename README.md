# Remote Browser on Unikraft Cloud

A single visual Chromium instance that supports both browser-based human access and authenticated CDP automation.

## Architecture

```text
Human operator
  -> HTTPS 443
  -> noVNC 6080
  -> x11vnc 5900
  -> Xvfb + Openbox
  -> Chromium

OpenCode / agent-browser
  -> TLS 10000
  -> authenticated CDP proxy 8080
  -> the same Chromium instance
```

Browser profile and CDP token data are stored on the persistent volume mounted at `/app/data`.

## Repository layout

```text
.github/workflows/deploy.yml   Manual production deployment workflow
deploy/visual-cdp/             Runtime image, launcher, and CDP proxy
```

Only one GitHub Actions workflow is retained. It uses `workflow_dispatch`, so pushes and pull requests do not start builds or deployments.

## Required GitHub configuration

Repository secrets:

```text
UKC_TOKEN
CDP_BOOTSTRAP_ADMIN_TOKEN
VNC_PASSWORD
```

Optional repository variable:

```text
UKC_METRO=fra
```

If `UKC_METRO` is absent, the workflow uses `fra`.

## Deploy

Open:

```text
GitHub -> Actions -> Deploy Remote Browser -> Run workflow
```

The workflow replaces the previous `visual-chromium-cdp` instance, reuses the existing persistent volume, builds the image, deploys it, and waits for both public endpoints.

## Connect to noVNC

Use the newest FQDN printed by the deployment workflow:

```text
https://<FQDN>/vnc.html
```

Enter the value stored in `VNC_PASSWORD` when prompted.

## Connect to CDP

Set the latest FQDN and the current CDP token locally:

```bash
export CDP_HOST='<FQDN>'
export CDP_TOKEN='<token>'
```

Retrieve the authenticated WebSocket endpoint:

```bash
CDP_WS=$(curl -fsS \
  "https://${CDP_HOST}:10000/json/version?token=${CDP_TOKEN}" \
  | jq -r '.webSocketDebuggerUrl')
```

Connect with `agent-browser` using the returned `wss://` URL:

```bash
agent-browser --cdp "$CDP_WS" open 'https://example.com'
agent-browser --cdp "$CDP_WS" snapshot -i
```

Use the `wss://` endpoint returned by `/json/version`. Do not pass the HTTPS discovery URL directly to `agent-browser`.

## Published ports

```text
443    -> 6080  noVNC over HTTP + TLS
10000  -> 8080  authenticated CDP over TLS
```

## Security

- Never commit API keys, cloud tokens, CDP tokens, VNC passwords, cookies, or browser profiles.
- Rotate any credential that appears in chat, terminal output, screenshots, or logs.
- Keep CDP authentication enabled and noVNC password protection configured.
