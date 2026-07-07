/* fake_claude.js — stands in for the Claude Code CLI in api_test.js. Records its
 * invocation (argv + stdin) to FAKE_CLAUDE_LOG and replies with the contents of
 * FAKE_CLAUDE_REPLY_FILE on stdout, exactly like `claude -p --output-format text`. */
'use strict';
const fs = require('fs');
let stdin = '';
process.stdin.on('data', c => stdin += c);
process.stdin.on('end', () => {
  fs.writeFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ argv: process.argv.slice(2), stdin }));
  process.stdout.write(fs.readFileSync(process.env.FAKE_CLAUDE_REPLY_FILE, 'utf8'));
});
