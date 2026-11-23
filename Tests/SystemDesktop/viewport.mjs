import assert from 'node:assert/strict';
import { DesktopViewport } from '../../scripts/vnc-client/viewport.mjs';

const viewport = new DesktopViewport();
const portrait = [402, 874, 1536, 1000];
const landscape = [874, 402, 1536, 1000];

let frame = viewport.frame(...portrait);
assert.equal(frame.left, 0);
assert.ok(frame.top > 300);
frame = viewport.frame(...landscape);
assert.equal(frame.top, 0);
assert.ok(frame.left < 130);

viewport.reset('fill');
frame = viewport.frame(...portrait);
assert.equal(frame.top, 0);
assert.ok(frame.left < 0);
assert.equal(frame.left, (portrait[0] - portrait[2] * frame.scale) / 2);

viewport.reset();
const anchor = {x: 145, y: 444};
const before = viewport.frame(...portrait);
const remoteX = (anchor.x - before.left) / before.scale;
viewport.gesture(...portrait, anchor, anchor, 2.4);
frame = viewport.frame(...portrait);
assert.ok(Math.abs((anchor.x - frame.left) / frame.scale - remoteX) < 0.001);

viewport.gesture(...portrait, anchor, {x: -5000, y: -5000}, 1);
frame = viewport.frame(...portrait);
assert.equal(frame.left, portrait[0] - portrait[2] * frame.scale);
const rotated = viewport.frame(...landscape);
assert.ok(rotated.left <= 0 && rotated.left >= landscape[0] - landscape[2] * rotated.scale);
assert.ok(rotated.top <= 0 && rotated.top >= landscape[1] - landscape[3] * rotated.scale);

viewport.reset();
assert.deepEqual(viewport.frame(...portrait), before);
console.log('Viewport fit, fill, pinch anchor, pan bounds, rotation, and reset verified');
