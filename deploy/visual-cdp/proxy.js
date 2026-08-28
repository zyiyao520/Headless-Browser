const {chromium} = require('playwright');
var http = require('http');
var httpProxy = require('http-proxy');
var modifyResponse = require('node-http-proxy-json');
var sem = require('semaphore')(1);
const crypto = require('crypto');
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const Debug = require('debug');

// ============================================================
// CONFIGURATION
// ============================================================

const port = 8080;
const cdp_host = '127.0.0.1';
const cdp_port = 9222;
const DB_PATH = process.env.DB_PATH || '/app/data/tokens.db';
const BOOTSTRAP_ADMIN_TOKEN = process.env.BOOTSTRAP_ADMIN_TOKEN;

var devtoolsPath = "";

// ============================================================
// LOGGING
// ============================================================

const debug = Debug('pw:*');
debug.log = function (...args) {
    const timestamp = new Date().toISOString();
    const formattedArgs = args.map(arg => (typeof arg === 'string' ? arg : JSON.stringify(arg)));
    console.log(`[${timestamp}] ${formattedArgs.join(' ')}`);
};

var log = console.log;
console.log = function () {
    var first_parameter = arguments[0];
    var other_parameters = Array.prototype.slice.call(arguments, 1);

    function formatConsoleDate (date) {
        var hour = date.getHours();
        var minutes = date.getMinutes();
        var seconds = date.getSeconds();
        var milliseconds = date.getMilliseconds();
        return '[' +
               ((hour < 10) ? '0' + hour: hour) +
               ':' +
               ((minutes < 10) ? '0' + minutes: minutes) +
               ':' +
               ((seconds < 10) ? '0' + seconds: seconds) +
               '.' +
               ('00' + milliseconds).slice(-3) +
               '] ';
    }

    log.apply(console, [formatConsoleDate(new Date()) + first_parameter].concat(other_parameters));
};

// ============================================================
// TOKEN DATABASE
// ============================================================

// Ensure data directory exists
const dbDir = path.dirname(DB_PATH);
if (!fs.existsSync(dbDir)) {
    fs.mkdirSync(dbDir, { recursive: true });
}

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.exec(`
  CREATE TABLE IF NOT EXISTS tokens (
    token TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_used INTEGER,
    expires_at INTEGER,
    is_admin INTEGER DEFAULT 0
  )
`);

function generateToken() {
    return crypto.randomBytes(32).toString('hex');
}

function createToken(name, expiresInDays, isAdmin) {
    const token = generateToken();
    const now = Date.now();
    const expiresAt = expiresInDays ? now + expiresInDays * 24 * 60 * 60 * 1000 : null;
    db.prepare(
        'INSERT INTO tokens (token, name, created_at, expires_at, is_admin) VALUES (?, ?, ?, ?, ?)'
    ).run(token, name, now, expiresAt, isAdmin ? 1 : 0);
    return { token, name, expiresAt, isAdmin: !!isAdmin };
}

function validateToken(token) {
    const row = db.prepare(
        'SELECT expires_at, is_admin FROM tokens WHERE token = ?'
    ).get(token);
    if (!row) return { valid: false };
    if (row.expires_at && Date.now() > row.expires_at) {
        db.prepare('DELETE FROM tokens WHERE token = ?').run(token);
        return { valid: false };
    }
    db.prepare('UPDATE tokens SET last_used = ? WHERE token = ?').run(Date.now(), token);
    return { valid: true, isAdmin: row.is_admin === 1 };
}

function revokeToken(token) {
    const result = db.prepare('DELETE FROM tokens WHERE token = ?').run(token);
    return result.changes > 0;
}

function listTokens() {
    return db.prepare(
        'SELECT token, name, created_at, last_used, expires_at, is_admin FROM tokens'
    ).all().map(t => ({
        token: t.token.slice(0, 8) + '...',
        fullToken: t.token,
        name: t.name,
        createdAt: new Date(t.created_at).toISOString(),
        lastUsed: t.last_used ? new Date(t.last_used).toISOString() : null,
        expiresAt: t.expires_at ? new Date(t.expires_at).toISOString() : null,
        isAdmin: t.is_admin === 1,
    }));
}

// Cleanup expired tokens periodically
setInterval(() => {
    const result = db.prepare(
        'DELETE FROM tokens WHERE expires_at IS NOT NULL AND expires_at < ?'
    ).run(Date.now());
    if (result.changes > 0) {
        console.log(`[Tokens] Cleaned up ${result.changes} expired tokens`);
    }
}, 60000);

// ============================================================
// AUTH HELPERS
// ============================================================

function extractToken(req) {
    // Check query parameter
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const queryToken = url.searchParams.get('token');
    if (queryToken) return queryToken;

    // Check Authorization header
    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
        return authHeader.slice(7);
    }
    return null;
}

function authenticate(req) {
    const token = extractToken(req);
    if (!token) return { authenticated: false, isAdmin: false };

    // Bootstrap admin token (from environment variable)
    if (BOOTSTRAP_ADMIN_TOKEN && token === BOOTSTRAP_ADMIN_TOKEN) {
        return { authenticated: true, isAdmin: true };
    }

    const result = validateToken(token);
    if (!result.valid) return { authenticated: false, isAdmin: false };
    return { authenticated: true, isAdmin: result.isAdmin };
}

function sendJson(res, statusCode, data) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try { resolve(JSON.parse(body)); }
            catch { reject(new Error('Invalid JSON')); }
        });
        req.on('error', reject);
    });
}

// ============================================================
// BROWSER STARTUP
// ============================================================

let browserContext;

async function startBrowser() {
    browserContext = await chromium.launchPersistentContext('/app/data/profile', {
        headless: false,
        args: [
            `--remote-debugging-port=${cdp_port}`,
            "--v=2",
            "--no-sandbox",
            "--disable-dev-shm-usage"
        ],
        logger: {
            isEnabled: () => true,
            log: (name, severity, message) => console.log(`${name} ${message}`)
        }
    });
}

function checkCdpReady() {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: cdp_host,
            port: cdp_port,
            path: '/json/version',
            method: 'GET',
            json: true
        };
        const req = http.request(options, (res) => {
            if (res.statusCode === 200) resolve(true);
            else reject(new Error(`Unexpected status code: ${res.statusCode}`));
        });
        req.on('error', (error) => reject(error));
        req.end();
    });
}

async function waitForDevtools() {
    const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    while (true) {
        try {
            await checkCdpReady();
            console.log('CDP is ready!');
            break;
        } catch (error) {
            console.log('Server not ready, retrying in 1 second...');
            await delay(1000);
        }
    }
}

function getDevtoolsPath() {
    return new Promise((resolve, reject) => {
        var options = {
            hostname: cdp_host,
            port: cdp_port,
            path: '/json/version',
            method: 'GET',
            json: true,
            timeout: 5000
        };
        var req = http.get(options, function(res) {
            let output = '';
            res.setEncoding('utf8');
            res.on('data', function(chunk) { output += chunk; });
            res.on('end', () => {
                try {
                    let obj = JSON.parse(output);
                    console.log("Chromium debugger endpoint discovered");
                    devtoolsPath = obj.webSocketDebuggerUrl.replace(`ws://${cdp_host}:${cdp_port}`, "");
                    console.log("devtoolsPath: " + devtoolsPath);
                    resolve();
                } catch (err) {
                    console.error('rest::end', err);
                    reject(err);
                }
            });
        });
        req.on('error', (error) => reject(`Problem with request: ${error.message}`));
        req.end();
    });
}

// ============================================================
// PROXY SERVER
// ============================================================

function runProxy() {
    var proxy = new httpProxy.createProxyServer({
        target: {
            host: cdp_host,
            port: cdp_port
        }
    });

    var proxyServer = http.createServer(function (req, res) {
        const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
        const pathname = url.pathname;

        // --- Public endpoints (no auth) ---

        if (pathname === '/health') {
            return sendJson(res, 200, { status: 'ok', timestamp: new Date().toISOString() });
        }

        // --- Token management API (admin only) ---

        if (pathname.startsWith('/api/tokens')) {
            const auth = authenticate(req);
            if (!auth.isAdmin) {
                return sendJson(res, auth.authenticated ? 403 : 401, {
                    error: auth.authenticated ? 'Admin access required' : 'Unauthorized'
                });
            }

            // POST /api/tokens - Create token
            if (req.method === 'POST' && pathname === '/api/tokens') {
                readBody(req).then(body => {
                    const { name, expiresInDays, isAdmin } = body;
                    if (!name) return sendJson(res, 400, { error: 'name is required' });
                    const created = createToken(name, expiresInDays, isAdmin);
                    console.log(`[Token] Created: ${name} (admin: ${!!isAdmin})`);
                    sendJson(res, 201, created);
                }).catch(() => sendJson(res, 400, { error: 'Invalid JSON body' }));
                return;
            }

            // GET /api/tokens - List tokens
            if (req.method === 'GET' && pathname === '/api/tokens') {
                return sendJson(res, 200, listTokens());
            }

            // DELETE /api/tokens/:token - Revoke token
            if (req.method === 'DELETE' && pathname.startsWith('/api/tokens/')) {
                const tokenToRevoke = pathname.slice('/api/tokens/'.length);
                const revoked = revokeToken(tokenToRevoke);
                if (revoked) {
                    console.log("[Token] Revoked");
                    return sendJson(res, 200, { revoked: true });
                }
                return sendJson(res, 404, { error: 'Token not found' });
            }

            return sendJson(res, 404, { error: 'Not found' });
        }

        // --- All other requests require authentication ---

        const auth = authenticate(req);
        if (!auth.authenticated) {
            return sendJson(res, 401, { error: 'Unauthorized' });
        }

        // --- Proxy to CDP ---
        console.log("incoming authenticated proxy request");
        req.headers['host'] = `${cdp_host}:${cdp_port}`;
        proxy.web(req, res);
    });

    proxy.on('proxyReq', function(proxyReq, req, res) {
        console.log("request path: " + new URL(req.url, `http://${req.headers.host || 'localhost'}`).pathname);
    });

    //
    // Update WebSocket URL in JSON response from Chrome CDP.
    //
    proxy.on('proxyRes', function (proxyRes, req, res) {
        if (res.req.url.startsWith("/json")) {
            console.log("CDP discovery response");
            const isHost = (element) => element == 'Host';
            host = res.req.rawHeaders[res.req.rawHeaders.findIndex(isHost)+1];

            // Carry the token from the original request into the rewritten WebSocket URL
            // so that Playwright can authenticate the subsequent WebSocket connection.
            const reqToken = extractToken(req);
            const tokenParam = reqToken ? `?token=${reqToken}` : '';

            modifyResponse(res, proxyRes, function (body) {
                if (body) {
                    console.log("rewriting Chromium debugger endpoint");
                    console.log(`rewrote WebSocket URL for host: ${host}`);
                    devtoolsPath = body.webSocketDebuggerUrl.replace(`ws://${cdp_host}:${cdp_port}`, "");
                    console.log(`devtoolsPath: ${devtoolsPath}`);
                    body.webSocketDebuggerUrl = `wss://${host}/unikraft${tokenParam}`;
                }
                return body;
            });

            res.setHeader('Host', host);
        }
    });

    //
    // WebSocket upgrade - requires authentication
    //
    proxyServer.on('upgrade', function (req, socket, head) {
        const auth = authenticate(req);
        if (!auth.authenticated) {
            socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
            socket.destroy();
            return;
        }

        console.log("before take (upgrade)");
        console.log("upgrade: devtoolsPath: " + devtoolsPath);
        sem.take(function() {
            console.log("authenticated WebSocket upgrade");
            req.url = devtoolsPath;
            proxy.ws(req, socket, head);
        });
    });

    proxy.on('close', function (res, socket, head) {
        console.log("websocket closed");
        sem.leave();
        console.log("after leave");
    });

    proxyServer.listen(port, () => {
        console.log('Server is running on port ' + port);
        console.log(`Token database: ${DB_PATH}`);
        if (BOOTSTRAP_ADMIN_TOKEN) {
            console.log("Bootstrap admin token is configured");
        }
    });
}

// ============================================================
// MAIN
// ============================================================

async function main() {
    try {
        await startBrowser();
        await waitForDevtools();
        await getDevtoolsPath();
        runProxy();
    } catch (error) {
        console.error(error);
    }
}

main();
