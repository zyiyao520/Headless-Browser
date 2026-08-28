#!/usr/bin/env python3
import asyncio
import os
from pathlib import Path
from aiohttp import WSMsgType, web

WEB_ROOT = Path(os.environ.get("NOVNC_WEB_ROOT", "/opt/novnc"))
VNC_HOST = os.environ.get("VNC_HOST", "127.0.0.1")
VNC_PORT = int(os.environ.get("VNC_PORT", "5901"))
LISTEN_PORT = int(os.environ.get("NOVNC_PORT", "6080"))

async def websocket_proxy(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(protocols=("binary",))
    await ws.prepare(request)
    reader, writer = await asyncio.open_connection(VNC_HOST, VNC_PORT)

    async def ws_to_tcp() -> None:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                writer.write(msg.data)
                await writer.drain()
            elif msg.type == WSMsgType.TEXT:
                writer.write(msg.data.encode())
                await writer.drain()
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break

    async def tcp_to_ws() -> None:
        while not ws.closed:
            data = await reader.read(65536)
            if not data:
                break
            await ws.send_bytes(data)

    tasks = [asyncio.create_task(ws_to_tcp()), asyncio.create_task(tcp_to_ws())]
    done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    writer.close()
    await writer.wait_closed()
    await ws.close()
    for task in done:
        if not task.cancelled():
            task.exception()
    return ws

async def root(_: web.Request) -> web.Response:
    raise web.HTTPFound("/vnc.html")

app = web.Application()
app.router.add_get("/", root)
app.router.add_get("/websockify", websocket_proxy)
app.router.add_static("/", WEB_ROOT, show_index=False)
web.run_app(app, host="0.0.0.0", port=LISTEN_PORT, print=None)
