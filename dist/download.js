'use strict';

const https = require('https');

// URLs and transport errors may contain credentials; never log them.
function httpsURL(value) {
  let url;
  try { url = new URL(value); }
  catch { throw new Error('invalid URL'); }
  if (url.protocol !== 'https:') throw new Error('URL requires HTTPS');
  if (url.username || url.password) throw new Error('URL user information is not supported');
  return url;
}

function get(url, {
  maxBytes,
  signal,
  timeoutMs = 120000,
  idleTimeoutMs = 30000,
} = {}) {
  return new Promise((resolve, reject) => {
    let request, response, timer;
    let settled = false;
    const finish = (error, body) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      if (error) {
        request?.destroy();
        response?.destroy();
        reject(error);
      } else resolve(body);
    };
    const fail = (message) => finish(new Error(message));
    const abort = () => fail('download cancelled');

    function visit(value, redirects) {
      if (settled) return;
      let target;
      try { target = httpsURL(value); }
      catch (error) { finish(error); return; }

      try {
        const req = https.get(target, {
          headers: { 'User-Agent': 'bitbison-github-action' },
        }, (res) => {
          if (settled) { res.destroy(); return; }
          response = res;
          res.on('error', () => {
            if (response === res) fail('download response failed');
          });

          if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
            let next;
            try { next = new URL(res.headers.location, target); }
            catch { fail('invalid download redirect'); return; }
            if (!res.headers.location) { fail('download redirect has no location'); return; }
            if (redirects === 0) { fail('too many download redirects'); return; }
            res.destroy();
            response = undefined;
            visit(next, redirects - 1);
            return;
          }
          if (res.statusCode !== 200) {
            fail(`download failed (HTTP ${res.statusCode})`);
            return;
          }
          if (Number(res.headers['content-length']) > maxBytes) {
            fail('download exceeds size limit');
            return;
          }

          const chunks = [];
          let size = 0, ended = false;
          res.on('data', (chunk) => {
            if (settled) return;
            size += chunk.length;
            if (size > maxBytes) { fail('download exceeds size limit'); return; }
            chunks.push(chunk);
          });
          res.on('aborted', () => fail('download response interrupted'));
          res.on('end', () => {
            ended = true;
            if (settled) return;
            if (!res.complete) { fail('download response interrupted'); return; }
            finish(null, Buffer.concat(chunks, size));
          });
          res.on('close', () => {
            if (!ended) fail('download response interrupted');
          });
        });
        request = req;
        req.setTimeout(idleTimeoutMs, () => fail('download stalled'));
        req.on('error', () => {
          if (request === req) fail('download request failed');
        });
      } catch { fail('download request failed'); }
    }

    if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
      fail('invalid download size limit');
      return;
    }
    if (signal?.aborted) { abort(); return; }
    signal?.addEventListener('abort', abort, { once: true });
    // Share one deadline across redirects.
    timer = setTimeout(() => fail('download timed out'), timeoutMs);
    visit(url, 3);
  });
}

module.exports = { get, httpsURL };
