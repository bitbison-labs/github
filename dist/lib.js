'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { get, httpsURL } = require('./download');

function input(name, def = '') {
  // GitHub preserves hyphens in input environment names.
  const v = process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`];
  return v === undefined || v === '' ? def : v.trim();
}

function appendEnvFile(envVar, line) {
  const f = process.env[envVar];
  if (f) fs.appendFileSync(f, line + '\n');
}
function saveState(name, value) { appendEnvFile('GITHUB_STATE', `${name}=${value}`); }
function getState(name) { return process.env[`STATE_${name}`] || ''; }
function escapeData(value) {
  return String(value).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}
function mask(secret) { if (secret) console.log(`::add-mask::${escapeData(secret)}`); }
function info(msg) { console.log(`bitbison: ${escapeData(msg)}`); }
function warn(msg) { console.log(`::warning::bitbison: ${escapeData(msg)}`); }

function maskInputs() {
  const channel = input('channel').replace(/\/+$/, '');
  mask(channel);
  mask(input('token'));
  mask(input('github-token'));
  mask(input('instance').replace(/\/+$/, ''));
  try {
    const key = new URL(channel).pathname.split('/')[1];
    mask(key);
    mask(decodeURIComponent(key));
  } catch {}
}

function arch() {
  return { x64: 'x86_64', arm64: 'aarch64' }[process.arch] || null;
}

async function bootstrap() {
  maskInputs();
  if (process.platform !== 'linux') { info('non-Linux runner; capture skipped.'); return null; }
  const a = arch();
  if (!a) { warn(`unsupported runner architecture ${process.arch}; capture skipped.`); return null; }
  const url = input('channel').replace(/\/+$/, '');
  if (!url) { warn('`channel` input is required (your Bitbison release channel URL); capture skipped.'); return null; }
  if (!input('token')) { warn('`token` input is required; capture skipped.'); return null; }
  if (!input('instance')) { warn('`instance` input is required; capture skipped.'); return null; }
  const channel = httpsURL(url);
  if (channel.search || channel.hash) throw new Error('channel URL must not contain a query or fragment');
  const instance = httpsURL(input('instance'));
  if (instance.search || instance.hash) throw new Error('instance URL must not contain a query or fragment');

  const base = `${url}/static/linux/${a}`;
  const controller = new AbortController();
  let sums, body;
  try {
    [sums, body] = await Promise.all([
      get(`${base}/SHA256SUMS`, { maxBytes: 1024 * 1024, signal: controller.signal }),
      get(`${base}/buildguard`, { maxBytes: 128 * 1024 * 1024, signal: controller.signal }),
    ]);
  } finally { controller.abort(); }
  const want = sums.toString('utf8').split('\n')
    .map((l) => l.trim().match(/^([0-9a-f]{64})\s+\*?buildguard$/))
    .filter(Boolean).map((m) => m[1])[0];
  if (!want) throw new Error('published SHA256SUMS has no entry for buildguard');
  const got = crypto.createHash('sha256').update(body).digest('hex');
  if (got !== want) throw new Error(`buildguard checksum mismatch (got ${got.slice(0, 12)}, want ${want.slice(0, 12)})`);

  let dir, bin;
  try {
    dir = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'bitbison-buildguard-'));
    bin = path.join(dir, 'buildguard');
    fs.writeFileSync(bin, body, { mode: 0o700, flag: 'wx' });
    saveState('bin', bin);
  } catch {
    try { if (dir) fs.rmSync(dir, { recursive: true, force: true }); }
    catch {}
    throw new Error('could not prepare buildguard in runner temporary storage');
  }
  info(`buildguard ${got.slice(0, 12)} fetched.`);
  return bin;
}

function env() {
  const e = { ...process.env };
  const put = (k, v) => { if (v) e[k] = v; };
  put('BITBISON_CHANNEL', input('channel').replace(/\/+$/, ''));
  put('BITBISON_TOKEN', input('token'));
  put('BITBISON_INSTANCE', input('instance'));
  put('BITBISON_MODE', input('mode'));
  put('BITBISON_LABEL', input('label'));
  put('BITBISON_NPM_SPANS', input('npm-spans'));
  put('BITBISON_VITE_SPANS', input('vite-spans'));
  // The job's token, for buildguard's read of the run's job list. It
  // reaches the buildguard process alone, never $GITHUB_ENV.
  put('BITBISON_GITHUB_TOKEN', input('github-token'));
  // Which job of the run this is: the workflow's own strategy and matrix
  // contexts, which no environment variable carries.
  put('BITBISON_MATRIX', input('matrix'));
  put('BITBISON_JOB_INDEX', input('job-index'));
  put('BITBISON_JOB_TOTAL', input('job-total'));
  put('BITBISON_JOB_CONTAINER', input('job-container'));
  put('BITBISON_JOB_SERVICES', input('job-services'));
  // Evaluated again for the post step, where it is the job's outcome.
  put('BITBISON_JOB_STATUS', input('job-status'));
  return e;
}

function run(bin, cmd) {
  if (!bin) return;
  maskInputs();
  const timeout = { start: 300000, status: 30000, finish: 600000 }[cmd];
  if (!timeout) { warn('unknown buildguard command; skipped.'); return; }
  try {
    const r = spawnSync(bin, [cmd], {
      stdio: 'inherit', env: env(), timeout, killSignal: 'SIGKILL',
    });
    if (r.error?.code === 'ETIMEDOUT') warn(`buildguard ${cmd} timed out after ${timeout / 1000}s`);
    else if (r.error) warn(`buildguard ${cmd} could not run`);
    else if (r.status !== 0) warn(`buildguard ${cmd} exited ${r.status ?? `on signal ${r.signal}`}`);
  } catch { warn(`buildguard ${cmd} could not run`); }
}

module.exports = { bootstrap, run, getState, info, warn };
