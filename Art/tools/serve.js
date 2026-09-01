// tools/serve.js — a static file server for the repo root (`npm run editor`),
// so tools/editor.html can pull in renderer/sprites.js with a plain <script>:
// most browsers refuse subresource loads over file://. Node builtins only,
// like every other script in tools/. Localhost, no caching, dev use only.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8173;
const ROOT = path.join(__dirname, '..');
const EDITOR = '/tools/editor.html';
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
};

const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(ROOT, path.normalize(url === '/' ? EDITOR : url));
  if (!file.startsWith(ROOT + path.sep)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('forbidden\n');
    return;
  }
  fs.readFile(file, (err, body) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found\n');
      return;
    }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(body);
  });
});

server.on('error', (err) => {
  console.error(
    err.code === 'EADDRINUSE'
      ? 'port ' + PORT + ' is already in use — another copy of this server is probably running.'
      : String(err),
  );
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Pomoppi icon editor: http://localhost:${PORT}${EDITOR}`);
  console.log('Ctrl-C to stop.');
});
