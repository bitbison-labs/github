'use strict';

const L = require('./lib');

const bin = L.getState('bin');
if (bin) L.run(bin, 'status');
else L.info('capture not active for this job.');
