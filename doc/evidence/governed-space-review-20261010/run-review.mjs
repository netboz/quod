import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const evidence = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(evidence, '../../..');
const attempt = process.argv[2];
if (!/^review-[0-9]+$/.test(attempt ?? '')) throw new Error('Pass a fresh review-N label');
const requestName = process.argv[3] ?? 'review-request.md';
if (!/^[a-z0-9-]+\.md$/.test(requestName)) throw new Error('Pass a local Markdown request filename');
const dir = path.join(evidence, attempt);
fs.mkdirSync(dir);
const tree = path.join(dir, 'tree');
const files = ['AGENTS.md', 'doc/world.md', 'doc/multiwrite-architecture.md', 'doc/proofs.md', 'doc/runtime-and-agents.md', 'doc/physics-native.md', 'doc/governed-physics-plan.md', 'priv/ontologies/space.pl', 'test/quod_space_tests.erl', 'priv/ontologies/common_predicates.pl', 'priv/ontologies/lobby_instance.pl', 'priv/ontologies/quod_lobby.pl', 'priv/ontologies/quod_physics.pl', 'priv/ontologies/fipa_request.pl', 'priv/ontologies/agent_instance.pl', 'src/quod_erlog_db_local_prove.erl', 'src/quod_prolog.erl', 'src/quod_runtime.erl', 'src/quod_client_goal_ingress.erl', 'src/quod_reg.erl', 'test/quod_agent_hosting_tests.erl', 'test/quod_physics_tests.erl', 'doc/evidence/space-ontology-review-20261010/followup-disposition.md'];
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const manifest = files.map(file => {
  const bytes = fs.readFileSync(path.join(root, file));
  const target = path.join(tree, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes, { flag: 'wx' });
  return { file, bytes: bytes.length, sha256: digest(bytes) };
});
const request = fs.readFileSync(path.join(evidence, requestName));
fs.writeFileSync(path.join(tree, 'review-request.md'), request, { flag: 'wx' });
const args = ['--print', '--model', 'fable', '--no-session-persistence',
  '--permission-mode', 'dontAsk', '--tools', 'Read,Grep,Glob',
  '--allowedTools', 'Read,Grep,Glob', '--disable-slash-commands',
  '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
  '--settings', '{"disableAllHooks":true}', '--output-format', 'json'];
const started = new Date().toISOString();
fs.writeFileSync(path.join(dir, 'source-manifest.json'), JSON.stringify({
  started, head: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
  files: manifest, request_name: requestName, request_sha256: digest(request),
  runner_sha256: digest(fs.readFileSync(fileURLToPath(import.meta.url))), args,
}, null, 2) + '\n', { flag: 'wx' });
const stdout = fs.openSync(path.join(dir, 'stdout.json'), 'wx');
const stderr = fs.openSync(path.join(dir, 'stderr.log'), 'wx');
const child = spawn('claude', args, { cwd: tree, stdio: ['pipe', stdout, stderr] });
let launchError = null;
child.on('error', error => { launchError = error.message; });
child.stdin.on('error', error => { launchError ??= error.message; });
child.stdin.end(request);
console.log(JSON.stringify({ attempt, pid: child.pid, started, frozen_files: manifest.length }));
child.on('close', (code, signal) => {
  fs.closeSync(stdout);
  fs.closeSync(stderr);
  let response = null, parseError = null;
  try { response = JSON.parse(fs.readFileSync(path.join(dir, 'stdout.json'), 'utf8')); }
  catch (error) { parseError = error.message; }
  if (typeof response?.result === 'string') {
    fs.writeFileSync(path.join(dir, 'fable-review.md'), response.result + '\n', { flag: 'wx' });
  }
  const changed = manifest.filter(row => digest(fs.readFileSync(path.join(tree, row.file))) !== row.sha256)
    .map(row => row.file);
  const receipt = { started, finished: new Date().toISOString(), code, signal, launchError,
    parseError, is_error: response?.is_error ?? null, subtype: response?.subtype ?? null,
    models: Object.keys(response?.modelUsage ?? {}), turns: response?.num_turns ?? null,
    changed_frozen_inputs: changed, report: typeof response?.result === 'string' };
  fs.writeFileSync(path.join(dir, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  console.log(JSON.stringify(receipt));
  process.exitCode = code !== 0 ? (code ?? 1) :
    launchError || parseError || response?.is_error || changed.length ? 1 : 0;
});
