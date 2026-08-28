# Unikraft Cloud 远程浏览器

在 Unikraft Cloud 上运行单实例可视化 Chromium，同时支持：

- 通过 noVNC 在浏览器中查看和人工操作桌面
- 通过带 Token 认证的 CDP 接口进行自动化控制
- 让 noVNC 与 CDP 操作同一个 Chromium 实例
- 使用持久化 Volume 保存浏览器配置、Cookie 和认证数据

## 架构

```text
人工操作
  -> HTTPS 443
  -> noVNC 6080
  -> x11vnc 5900
  -> Xvfb + Openbox
  -> Chromium

OpenCode / agent-browser
  -> TLS 10000
  -> CDP 认证代理 8080
  -> 同一个 Chromium
```

浏览器 Profile 和 CDP Token 数据保存在挂载到 `/app/data` 的持久化 Volume 中。

## 仓库结构

```text
.github/workflows/deploy.yml   手动部署工作流
deploy/visual-cdp/Dockerfile   Unikraft Rootfs 构建文件
deploy/visual-cdp/Kraftfile    Unikraft 运行配置
deploy/visual-cdp/proxy.js     Chromium 启动与 CDP 认证代理
deploy/visual-cdp/visual-entrypoint.sh
                               Xvfb、Openbox、x11vnc、noVNC 启动脚本
deploy/visual-cdp/wrapper.sh   运行环境包装脚本
```

仓库只保留一个 GitHub Actions 工作流，并且仅支持 `workflow_dispatch` 手动触发。推送代码或创建 Pull Request 不会自动构建或部署。

## 前置配置

进入：

```text
GitHub 仓库 -> Settings -> Secrets and variables -> Actions
```

创建以下 Repository Secrets：

```text
UKC_TOKEN                    Unikraft Cloud 访问令牌
CDP_BOOTSTRAP_ADMIN_TOKEN    CDP 管理员 Token
VNC_PASSWORD                 noVNC 登录密码
```

可选 Repository Variable：

```text
UKC_METRO=fra
```

未设置 `UKC_METRO` 时，工作流默认使用 `fra`。

请勿将上述 Secret 写入仓库、日志、截图或聊天记录。

## 部署

打开：

```text
GitHub -> Actions -> Deploy Remote Browser -> Run workflow
```

工作流会执行以下操作：

1. 删除旧的 `visual-chromium-cdp` 实例。
2. 等待持久化 Volume 解除挂载。
3. 按需删除旧应用镜像。
4. 复用或创建 `chromium-cdp-auth-data` Volume。
5. 构建并部署新的可视化 Chromium 实例。
6. 检查 noVNC 与 CDP 公网端点。
7. 上传实例状态和限时运行日志。

部署完成后，以本次工作流输出的最新 FQDN 为准。实例重建后，旧 FQDN 会失效。

## 连接 noVNC

访问：

```text
https://<最新 FQDN>/vnc.html
```

在 noVNC 密码框中输入 Repository Secret `VNC_PASSWORD` 对应的值。

## 连接 CDP

本地设置最新 FQDN 和当前 CDP Token：

```bash
export CDP_HOST='<最新 FQDN>'
export CDP_TOKEN='<当前 CDP Token>'
```

先获取 CDP WebSocket 地址：

```bash
CDP_WS=$(curl -fsS \
  "https://${CDP_HOST}:10000/json/version?token=${CDP_TOKEN}" \
  | jq -r '.webSocketDebuggerUrl')
```

确认地址是 `wss://`：

```bash
printf '%s\n' "$CDP_WS"
```

使用 `agent-browser` 连接：

```bash
agent-browser --cdp "$CDP_WS" open 'https://example.com'
agent-browser --cdp "$CDP_WS" snapshot -i
```

必须使用 `/json/version` 返回的 `wss://` WebSocket URL。不要把 HTTPS 探测地址直接传给 `agent-browser`。

## 公网端口

```text
443    -> 6080   noVNC，HTTP + TLS
10000  -> 8080   CDP 认证代理，TLS
```

内部端口：

```text
5900   x11vnc
6080   noVNC / websockify
8080   CDP 认证代理
9222   Chromium CDP
```

## 验收步骤

### 1. 验证 noVNC

打开：

```text
https://<最新 FQDN>/vnc.html
```

确认：

- 页面可以加载
- 会要求输入 VNC 密码
- 输入密码后能看到 Chromium 桌面

### 2. 验证 CDP

```bash
curl -i \
  "https://${CDP_HOST}:10000/json/version?token=${CDP_TOKEN}"
```

预期返回：

```text
HTTP 200
```

响应中应包含：

```json
{
  "webSocketDebuggerUrl": "wss://..."
}
```

### 3. 验证同一个浏览器

通过 `agent-browser` 打开页面：

```bash
agent-browser --cdp "$CDP_WS" open 'https://example.com/?source=agent'
```

然后在 noVNC 中确认同一页面可见。再在 noVNC 中打开其他页面，并通过 `agent-browser` 读取当前 URL。

### 4. 验证持久化

在 Chromium 中建立测试登录状态，重新部署并复用原 Volume，然后确认 Cookie、Local Storage 和 Profile 状态仍然存在。

## 常见问题

### `There is no service on this URL`

通常表示使用了旧 FQDN。重新部署实例后 Service 地址会变化，请使用最新工作流输出中的域名。

### CDP 返回 `Unauthorized`

说明 CDP 代理可达，但 Token 缺失或不正确。检查本地 `CDP_TOKEN` 是否与当前实例部署时使用的 `CDP_BOOTSTRAP_ADMIN_TOKEN` 一致。

### `agent-browser` 使用 HTTPS 地址时挂起

不要直接使用：

```text
https://<FQDN>:10000?token=...
```

应先调用 `/json/version`，再使用返回的 `wss://` 地址。

### 工作流健康检查失败

下载工作流 Artifact，重点查看：

```text
visual-instance.json
visual-instance.log
visual-images.json
```

日志中会显示 Xvfb、Openbox、x11vnc、noVNC 和 Chromium/CDP 的启动信息。

## 安全建议

- CDP 必须保持 Token 认证。
- noVNC 必须保持密码认证。
- Token、VNC 密码、Cookie 和 Profile 不得提交到 Git。
- 凭据一旦出现在聊天、终端输出、截图或日志中，应立即轮换。
- 不要复用已经公开或泄露的 Token。
