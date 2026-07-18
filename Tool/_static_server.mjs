import http from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { join, extname } from 'node:path';

const root = process.argv[2];
const port = Number(process.argv[3] || 8123);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png', '.pck': 'application/octet-stream' };

http.createServer((req, res) => {
  const file = join(root, decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
  try {
    const st = statSync(file);
    res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream', 'Content-Length': st.size });
    createReadStream(file).pipe(res);
  } catch {
    res.writeHead(404); res.end('not found');
  }
}).listen(port, () => console.log('serving', root, 'on', port));
