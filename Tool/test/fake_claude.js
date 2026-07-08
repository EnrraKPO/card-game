/* fake_claude.js — stands in for the Claude Code CLI in api_test.js. Records its
 * invocation (argv + stdin + the resolved system prompt, read here because the adapter
 * deletes its per-call temp dir on exit) to FAKE_CLAUDE_LOG and replies with the
 * contents of FAKE_CLAUDE_REPLY_FILE on stdout, like `claude -p --output-format text`. */
'use strict';
const fs = require('fs');
let stdin = '';
process.stdin.on('data', c => stdin += c);
process.stdin.on('end', () => {
  const argv = process.argv.slice(2);
  const i = argv.indexOf('--system-prompt-file');
  let systemPrompt = '';
  try { systemPrompt = fs.readFileSync(argv[i + 1], 'utf8'); } catch (e) { /* left empty */ }
  // reference images are also temp files — capture their bytes while they exist
  const refs = [];
  for (const m of stdin.matchAll(/Read tool: (.+\.png)/g)) {
    try { refs.push({ path: m[1], data: fs.readFileSync(m[1]).toString('base64') }); }
    catch (e) { refs.push({ path: m[1], missing: true }); }
  }
  fs.writeFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ argv, stdin, systemPrompt, refs }));
  process.stdout.write(fs.readFileSync(process.env.FAKE_CLAUDE_REPLY_FILE, 'utf8'));
});
