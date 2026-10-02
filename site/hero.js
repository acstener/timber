// Timber hero: a low-poly island under a lidar sweep. Trees sprout like a live survey;
// click one to chop it.
import * as THREE from 'three';

const canvas = document.getElementById('island');
const tip = document.getElementById('tip');
const hint = document.getElementById('hint');
const hudFiles = document.getElementById('hud-files');
const hudReclaimed = document.getElementById('hud-reclaimed');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const mobile = innerWidth < 900;

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, mobile ? 1.5 : 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;

const scene = new THREE.Scene();
scene.fog = new THREE.Fog(0xcfe8f5, 40, 110);
const camera = new THREE.PerspectiveCamera(36, 1, 0.1, 400);
const pivot = new THREE.Group();
scene.add(pivot);
pivot.add(camera);
camera.position.set(0, 15, 37);
const target = new THREE.Vector3(0, 0.6, 0);

// lights
scene.add(new THREE.HemisphereLight(0xdff1ff, 0x6c8f5a, 1.4));
const sun = new THREE.DirectionalLight(0xfff1dc, 2.6);
sun.position.set(-18, 28, 14);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
Object.assign(sun.shadow.camera, { left: -18, right: 18, top: 18, bottom: -18, near: 1, far: 80 });
sun.shadow.radius = 4;
scene.add(sun);

// rng
let seed = 42;
const rnd = (a = 0, b = 1) => { seed = (seed * 16807) % 2147483647; return a + (b - a) * (seed / 2147483647); };

// terrain
const R = 13;
const height = (x, z) => {
  const r = Math.hypot(x, z);
  const hills = 0.55 * Math.sin(x * 0.33 + 1.3) * Math.cos(z * 0.29 - 0.4) + 0.35 * Math.sin(x * 0.7 + z * 0.55) + 0.2 * Math.cos(x * 1.5 - z * 1.2);
  const t = Math.min(1, Math.max(0, (r - R * 0.68) / (R * 0.32)));
  const fall = t * t * (3 - 2 * t);
  return (1 + hills * 0.7) * (1 - fall) - 0.9 * fall;
};
{
  const n = mobile ? 44 : 64, size = (R + 1.2) * 2, step = size / n;
  const pos = [], col = [];
  const jit = (i, j) => { const s = Math.sin(i * 12.9898 + j * 78.233) * 43758.5453; return (s - Math.floor(s)) - 0.5; };
  const P = (i, j) => {
    const edge = i === 0 || j === 0 || i === n || j === n;
    const x = -size / 2 + i * step + (edge ? 0 : jit(i, j) * 0.24);
    const z = -size / 2 + j * step + (edge ? 0 : jit(j, i) * 0.24);
    return [x, height(x, z), z];
  };
  const sand = new THREE.Color(0xe6d49a), low = new THREE.Color(0x7dbb5c), high = new THREE.Color(0x4d944a);
  const tri = (a, b, c) => {
    const cx = (a[0] + b[0] + c[0]) / 3, cy = (a[1] + b[1] + c[1]) / 3, cz = (a[2] + b[2] + c[2]) / 3;
    if (Math.hypot(cx, cz) > R + 1.2) return;
    const k = Math.min(1, Math.max(0, (cy - 0.2) / 1.4));
    const c0 = cy < 0.2 ? sand.clone() : low.clone().lerp(high, k);
    c0.multiplyScalar(0.92 + rnd() * 0.16);
    for (const v of [a, b, c]) { pos.push(...v); col.push(c0.r, c0.g, c0.b); }
  };
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    const a = P(i, j), b = P(i, j + 1), c = P(i + 1, j), d = P(i + 1, j + 1);
    tri(a, b, c); tri(c, b, d);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
  g.computeVertexNormals();
  const m = new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true });
  // lidar sweep + contour lines + ring pulses, painted as emission
  m.onBeforeCompile = (sh) => {
    sh.uniforms.uTime = timeU;
    sh.uniforms.uScan = scanU;
    sh.vertexShader = sh.vertexShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vWP;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvWP = (modelMatrix * vec4(transformed, 1.0)).xyz;');
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nuniform float uTime;\nuniform float uScan;')
      .replace('#include <emissivemap_fragment>', `#include <emissivemap_fragment>
        float ang = atan(vWP.z, vWP.x);
        float sweep = mod(uTime * 1.15, 6.2831853);
        float d = mod(sweep - ang + 12.5663706, 6.2831853);
        float trail = exp(-d * 1.9);
        float edge = exp(-d * 40.0);
        float r = length(vWP.xz);
        float ph = fract(uTime * 0.2);
        float ring = exp(-pow((r - ph * 16.0) * 2.2, 2.0)) * (1.0 - ph);
        float contour = smoothstep(0.86, 1.0, fract(vWP.y * 6.0));
        float glow = trail * (0.15 + contour * 1.2) + edge * 1.3 + ring * (0.5 + contour);
        totalEmissiveRadiance += vec3(1.0, 0.45, 0.12) * glow * uScan;`);
  };
  const island = new THREE.Mesh(g, m);
  island.receiveShadow = true;
  scene.add(island);
}
const timeU = { value: 0 }, scanU = { value: 1 };

// water
{
  const w = new THREE.Mesh(new THREE.CircleGeometry(220, 64), new THREE.MeshStandardMaterial({ color: 0x5aa7da, roughness: 0.35, metalness: 0.05 }));
  w.rotation.x = -Math.PI / 2; w.position.y = 0.02; w.receiveShadow = true;
  scene.add(w);
}

// clouds
const clouds = [];
{
  const cm = new THREE.MeshLambertMaterial({ color: 0xffffff, emissive: 0x666666 });
  for (let i = 0; i < 7; i++) {
    const c = new THREE.Group();
    for (let k = 0; k < 5; k++) {
      const s = new THREE.Mesh(new THREE.IcosahedronGeometry(rnd(0.9, 1.7), 1), cm);
      s.position.set(k * 1.1 - 2.2, rnd(-0.3, 0.4), rnd(-0.5, 0.5)); s.scale.y = 0.62;
      c.add(s);
    }
    const a = i / 7 * Math.PI * 2, d = rnd(30, 46);
    c.position.set(Math.cos(a) * d, rnd(12, 17), Math.sin(a) * d);
    c.userData.speed = rnd(0.2, 0.5);
    scene.add(c); clouds.push(c);
  }
}

// trees
const mats = {};
const mat = (hex) => (mats[hex] ??= new THREE.MeshLambertMaterial({ color: hex, flatShading: true }));
const BARK = 0x6b4a32;
function makeTree(kind, h) {
  const t = new THREE.Group();
  const add = (geo, color, y, x = 0, z = 0) => { const m = new THREE.Mesh(geo, mat(color)); m.position.set(x, y, z); m.castShadow = true; t.add(m); return m; };
  if (kind === 'pine') {
    add(new THREE.CylinderGeometry(h * 0.04, h * 0.06, h * 0.3, 6), BARK, h * 0.15);
    const g = [0x2f7d4f, 0x3a8a55, 0x2c6e4a, 0x45935a][Math.floor(rnd(0, 4))];
    for (let i = 0; i < 3; i++) add(new THREE.ConeGeometry(h * (0.3 - i * 0.065), h * 0.42, 7), g, h * (0.4 + i * 0.2));
  } else if (kind === 'dead') {
    add(new THREE.CylinderGeometry(h * 0.03, h * 0.06, h * 0.75, 5), 0x8a7563, h * 0.375);
    for (let i = 0; i < 4; i++) {
      const b = add(new THREE.CylinderGeometry(h * 0.015, h * 0.025, h * 0.35, 4), 0x8a7563, h * (0.5 + i * 0.1), (i % 2 ? 1 : -1) * h * 0.1);
      b.rotation.z = (i % 2 ? -1 : 1) * rnd(0.6, 0.95); b.rotation.y = rnd(0, 6.28);
    }
  } else {
    const leaf = { oak: 0x5da84e, blossom: 0xf4a6c0, birch: 0xf2c14e, maple: 0xe2582e }[kind];
    add(new THREE.CylinderGeometry(h * (kind === 'birch' ? 0.03 : 0.045), h * 0.06, h * 0.55, 6), kind === 'birch' ? 0xf1eee6 : BARK, h * 0.275);
    const crown = add(new THREE.IcosahedronGeometry(h * 0.3, 0), leaf, h * 0.7);
    if (kind === 'birch') crown.scale.set(0.85, 1.25, 0.85);
    for (let i = 0; i < 3; i++) {
      const a = rnd(0, 6.28);
      add(new THREE.IcosahedronGeometry(h * rnd(0.15, 0.21), 0), leaf, h * rnd(0.6, 0.85), Math.cos(a) * h * 0.24, Math.sin(a) * h * 0.24);
    }
  }
  return t;
}

// A make-believe Mac, biggest folders last (like a real scan).
const forest = [
  ['old-site/node_modules', 1.7, 'dead'], ['.next · storefront', 1.4, 'dead'], ['Slack cache', 2.3, 'dead'],
  ['Figma.dmg', 0.4, 'birch'], ['Thesis', 0.6, 'oak'], ['Music', 6.2, 'blossom'], ['.build · cli', 5.0, 'dead'],
  ['pnpm store', 3.3, 'dead'], ['Downloads', 9.8, 'pine'], ['Xcode.xip', 11.2, 'birch'], ['Docker.raw', 24, 'oak'],
  ['DerivedData', 9.4, 'dead'], ['Simulators', 17.2, 'dead'], ['Photos', 21, 'blossom'], ['Movies', 38, 'blossom'],
  ['Projects', 31, 'pine'], ['Applications', 26, 'maple'], ['Library', 106, 'pine'],
  ['notes', 0.2, 'oak'], ['dotfiles', 0.1, 'pine'], ['game-jam', 0.8, 'pine'], ['podcast', 3.1, 'blossom'],
  ['fonts', 0.3, 'oak'], ['sketches', 0.5, 'oak'], ['invoices', 0.2, 'pine'], ['wallpapers', 1.1, 'blossom'],
  ['ml-experiments', 4.2, 'pine'], ['voice-memos', 0.9, 'blossom'], ['Zoom', 0.6, 'maple'], ['Spotify cache', 3.8, 'dead'],
];
const placed = [];
const trees = [];
const spot = (r) => {
  let best = [0, 0], bestGap = -Infinity;
  for (let k = 0; k < 40; k++) {
    const a = rnd(0, 6.28), d = R * 0.76 * Math.sqrt(rnd());
    const x = Math.cos(a) * d, z = Math.sin(a) * d;
    let gap = 10;
    for (const p of placed) gap = Math.min(gap, Math.hypot(p.x - x, p.z - z) - (p.r + r) * 0.8);
    if (gap > 0) return [x, z];
    if (gap > bestGap) { bestGap = gap; best = [x, z]; }
  }
  return best;
};
const heightFor = (gb) => Math.max(0.5, Math.min(6.4, 0.45 + 5.4 * Math.pow(gb / 100, 0.32)));

function sprout([name, gb, kind], delay) {
  const h = heightFor(gb), r = h * 0.3;
  const [x, z] = spot(r); placed.push({ x, z, r });
  const t = makeTree(kind, h);
  t.position.set(x, height(x, z) - 0.05, z);
  t.rotation.y = rnd(0, 6.28);
  t.scale.setScalar(0.0001);
  t.userData = { name, gb, kind, h, born: performance.now() / 1000 + delay, sway: rnd(0, 6.28) };
  scene.add(t); trees.push(t);
}
const order = forest.slice(0, mobile ? 20 : 30).map((t, i) => [t, i]);
order.forEach(([t, i]) => sprout(t, reduced ? 0 : 0.5 + i * 0.16));
const totalFiles = 3361921;

// particles
const chips = [];
const chipGeo = new THREE.BoxGeometry(0.12, 0.05, 0.06);
function burst(at, color, n, up = 3) {
  for (let i = 0; i < n; i++) {
    const m = new THREE.Mesh(chipGeo, mat(color));
    m.position.copy(at);
    m.userData = { v: new THREE.Vector3(rnd(-1.5, 1.5), rnd(1, up), rnd(-1.5, 1.5)), life: rnd(0.8, 1.4), spin: rnd(-10, 10) };
    scene.add(m); chips.push(m);
  }
}

// sound: a synthesised thunk + crash, only after a click
let actx;
function thunk(big = false) {
  try {
    actx ??= new AudioContext();
    const t0 = actx.currentTime, o = actx.createOscillator(), g = actx.createGain();
    o.frequency.setValueAtTime(big ? 90 : 170, t0); o.frequency.exponentialRampToValueAtTime(big ? 40 : 70, t0 + (big ? 0.5 : 0.15));
    g.gain.setValueAtTime(big ? 0.5 : 0.35, t0); g.gain.exponentialRampToValueAtTime(0.001, t0 + (big ? 0.7 : 0.22));
    o.connect(g).connect(actx.destination); o.start(t0); o.stop(t0 + 0.8);
    if (big) {
      const len = actx.sampleRate * 0.6, buf = actx.createBuffer(1, len, actx.sampleRate), d = buf.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
      const s = actx.createBufferSource(), f = actx.createBiquadFilter(), ng = actx.createGain();
      f.type = 'lowpass'; f.frequency.value = 900; ng.gain.value = 0.35;
      s.buffer = buf; s.connect(f).connect(ng).connect(actx.destination); s.start(t0);
    }
  } catch {}
}

// interaction
const ray = new THREE.Raycaster(), mouse = new THREE.Vector2();
let hovered = null, reclaimed = 0, maxProgress = 0;
const project = (v) => { const p = v.clone().project(camera); const b = canvas.getBoundingClientRect(); return [(p.x + 1) / 2 * b.width, (1 - p.y) / 2 * b.height]; };
const treeAt = (e) => {
  const b = canvas.getBoundingClientRect();
  mouse.set(((e.clientX - b.left) / b.width) * 2 - 1, -((e.clientY - b.top) / b.height) * 2 + 1);
  ray.setFromCamera(mouse, camera);
  const hits = ray.intersectObjects(trees.filter(t => !t.userData.chopping), true);
  let o = hits[0]?.object; while (o && !trees.includes(o)) o = o.parent;
  return o || null;
};
const fmt = (gb) => gb >= 1 ? `${gb.toFixed(1)} GB` : `${Math.round(gb * 1000)} MB`;
canvas.addEventListener('pointermove', (e) => {
  const t = treeAt(e);
  if (t !== hovered) {
    hovered?.traverse(m => m.material && (m.material = m.userData.base ?? m.material));
    hovered = t;
    hovered?.traverse(m => { if (m.material) { m.userData.base = m.material; const c = m.material.clone(); c.emissive = new THREE.Color(0x553311); m.material = c; } });
  }
  canvas.style.cursor = t ? 'pointer' : 'grab';
  if (t) {
    const [x, y] = project(t.position.clone().add(new THREE.Vector3(0, t.userData.h + 0.4, 0)));
    tip.innerHTML = `${t.userData.name}<small>${fmt(t.userData.gb)}</small>`;
    tip.style.left = x + 'px'; tip.style.top = y + 'px'; tip.style.opacity = 1;
  } else tip.style.opacity = 0;
});
canvas.addEventListener('pointerleave', () => { tip.style.opacity = 0; });
canvas.addEventListener('click', (e) => {
  const t = treeAt(e);
  if (!t) return;
  hint.classList.add('gone');
  tip.style.opacity = 0;
  const u = t.userData;
  u.chopping = performance.now() / 1000;
  const away = new THREE.Vector3().subVectors(t.position, camera.getWorldPosition(new THREE.Vector3())).setY(0).normalize();
  u.axis = new THREE.Vector3(away.z, 0, -away.x).normalize(); // fall away from the camera-ish, sideways
  u.q0 = t.quaternion.clone();
  thunk();
  setTimeout(() => thunk(), 260);
  burst(t.position.clone().add(new THREE.Vector3(0, u.h * 0.12, 0)), 0xe9c894, 14);
  setTimeout(() => {
    const [x, y] = project(t.position.clone().add(new THREE.Vector3(0, u.h, 0)));
    floatText('TIMBER!', x, y, 'timber');
  }, 450);
  setTimeout(() => {
    thunk(true);
    burst(t.position.clone().add(new THREE.Vector3(0, 0.3, 0)), u.kind === 'blossom' ? 0xf4a6c0 : 0x5da84e, 26, 4);
    reclaimed += u.gb;
    hudReclaimed.textContent = fmt(reclaimed);
    const [x, y] = project(t.position.clone().add(new THREE.Vector3(0, 1, 0)));
    floatText('+' + fmt(u.gb), x, y);
    window.posthog?.capture?.('hero_tree_chopped');
  }, 1250);
});
function floatText(text, x, y, cls = '') {
  const el = document.createElement('div');
  el.className = 'float ' + cls; el.textContent = text;
  el.style.left = x + 'px'; el.style.top = y + 'px';
  canvas.parentElement.appendChild(el);
  setTimeout(() => el.remove(), 1500);
}

// drag to orbit
let dragging = false, lastX = 0, spin = 0;
canvas.addEventListener('pointerdown', (e) => { dragging = true; lastX = e.clientX; });
addEventListener('pointerup', () => { dragging = false; });
addEventListener('pointermove', (e) => { if (dragging) { spin += (e.clientX - lastX) * 0.005; lastX = e.clientX; } });

// resize
function resize() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  // Shift the island to the right of the headline on wide screens.
  if (w > 900) camera.setViewOffset(w, h, -w * 0.27, -h * 0.03, w, h); else camera.clearViewOffset();
  camera.updateProjectionMatrix();
}
addEventListener('resize', resize); resize();

// loop
const clock = new THREE.Clock();
let visible = true;
new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(canvas);
const easeOutBack = (x) => { const c1 = 1.9, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2); };
function frame() {
  requestAnimationFrame(frame);
  if (!visible) return;
  const dt = Math.min(clock.getDelta(), 0.05), now = performance.now() / 1000, t = clock.elapsedTime;
  timeU.value = t;
  if (!reduced) pivot.rotation.y += dt * 0.06;
  pivot.rotation.y += spin; spin *= 0.85;
  camera.lookAt(target);

  let grown = 0;
  for (let i = trees.length - 1; i >= 0; i--) {
    const tr = trees[i], u = tr.userData;
    if (u.chopping) {
      const k = now - u.chopping;
      if (k < 0.55) { tr.position.x += Math.sin(k * 80) * 0.004; }
      else {
        const f = Math.min(1, (k - 0.55) / 0.7);
        const ang = (Math.PI / 2 - 0.08) * f * f;
        tr.quaternion.copy(u.q0).premultiply(new THREE.Quaternion().setFromAxisAngle(u.axis, ang));
        if (k > 1.6) tr.scale.multiplyScalar(0.9);
        if (k > 2.4) { scene.remove(tr); trees.splice(i, 1); }
      }
      continue;
    }
    const age = now - u.born;
    if (age < 0) continue;
    grown++;
    const s = age < 0.9 ? Math.max(0.0001, easeOutBack(age / 0.9)) : 1;
    tr.scale.setScalar(s);
    tr.rotation.z = Math.sin(t * 0.9 + u.sway) * 0.02;
  }
  // survey counter climbs while trees sprout, then the sweep calms
  const progress = (maxProgress = Math.max(maxProgress, Math.min(1, grown / order.length)));
  hudFiles.textContent = Math.round(totalFiles * progress).toLocaleString();
  scanU.value += ((progress < 1 ? 1 : 0.35) - scanU.value) * 0.02;

  for (let i = chips.length - 1; i >= 0; i--) {
    const c = chips[i], u = c.userData;
    u.v.y -= 9 * dt; c.position.addScaledVector(u.v, dt); c.rotation.x += u.spin * dt; c.rotation.y += u.spin * dt;
    u.life -= dt;
    if (u.life <= 0 || c.position.y < -1) { scene.remove(c); chips.splice(i, 1); }
  }
  for (const c of clouds) c.position.x += Math.sin(t * 0.05) * c.userData.speed * dt;
  renderer.render(scene, camera);
}
frame();
