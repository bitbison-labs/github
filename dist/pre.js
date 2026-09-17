'use strict';

const L = require('./lib');

L.bootstrap()
  .then((bin) => L.run(bin, 'start'))
  .catch((e) => L.warn(`setup failed (non-fatal): ${e.message}`));
