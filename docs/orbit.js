// A ring of dots around the real panel. On load the bead goes round once and the ring forms behind it.
// Then the tabs move on by themselves and the bead is their clock: it reaches the next tab's place on the ring as that tab comes up.
// You can grab the ball and throw it: it spins with momentum, the tabs flip as it passes them, and it lands on one.
// Pointing at the panel or the list holds it. Picking a tab holds it for a while. It stops when it's off screen, and with reduced motion it never runs.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const DWELL = 6500;    // ms on each tab
  const HOLD = 16000;    // ms it stays on a tab you picked

  // The words beside a capture and the capture itself stay on the same tab.
  const makeTour = (tour) => {
    const box = document.querySelector(tour.dataset.real);
    const buttons = [...tour.querySelectorAll('[data-tab]')];
    const about = [...tour.querySelectorAll('[data-about]')];
    const words = tour.querySelector('.about');
    const ids = buttons.map((b) => b.dataset.tab);
    const t = { current: tour.dataset.start, elapsed: 0, visible: false, hover: false, focus: false, holdUntil: 0 };
    const mark = (id) => {
      for (const b of buttons) b.setAttribute('aria-pressed', String(b.dataset.tab === id));
      for (const p of about) p.classList.toggle('on', p.dataset.about === id);
    };
    for (const b of buttons) b.addEventListener('click', () => box.show(b.dataset.tab));
    box.addEventListener('real:change', ({ detail: { id, auto } }) => {
      // Only say it aloud when someone asked for it, not every few seconds.
      words.setAttribute('aria-live', auto ? 'off' : 'polite');
      mark(id);
      t.current = id;
      t.elapsed = 0;
      if (!auto) t.holdUntil = performance.now() + HOLD;
    });
    for (const el of [box, tour]) {
      el.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') t.hover = true; });
      el.addEventListener('pointerleave', () => { t.hover = false; });
      el.addEventListener('focusin', (e) => { t.focus = e.target.matches(':focus-visible'); });
      el.addEventListener('focusout', () => { t.focus = false; });
    }
    new IntersectionObserver(([e]) => { t.visible = e.isIntersecting; }, { threshold: 0.35 }).observe(box);
    t.active = (now) => !reduce && t.visible && !t.hover && !t.focus && !document.hidden && now >= t.holdUntil;
    t.tick = (dt, now) => {
      if (!t.active(now)) return;
      t.elapsed += dt;
      if (t.elapsed >= DWELL) box.show(ids[(ids.indexOf(t.current) + 1) % ids.length], true);
    };
    mark(t.current);
    return t;
  };
  const panelTour = makeTour(document.querySelector('.scene .tour'));

  const stage = document.querySelector('.orbit');
  const canvas = stage.querySelector('canvas');
  const panel = stage.querySelector('.real');
  const gl = canvas.getContext('webgl', { alpha: true, antialias: false, premultipliedAlpha: true });
  if (!gl) { canvas.remove(); return; }

  const TAU = Math.PI * 2;
  const REST = (-120 * Math.PI) / 180;
  const FIELD = 136;   // the canvas reaches this far from the centre; the ring is at 100
  const STOPS = { notes: -180, history: -120, auth: -60, scripts: 0, sous: 60, temper: 120 };

  const VS = `
    attribute vec3 a;                 // x, y, kind: 0 field, 1 bead
    uniform float scale, dpr, bead, sweep, beadIn, press;
    uniform vec2 ptr, res;
    varying vec4 col;
    const float TAU = 6.2831853, R = 100.0, REST = -2.0943951, GAP = 0.17;
    float delta(float x, float y) { return abs(mod(x - y + TAU * 0.5, TAU) - TAU * 0.5); }
    void main() {
      vec2 b = R * vec2(cos(bead), sin(bead));
      vec2 q; float size; float al;
      if (a.z > 0.5) {
        q = b + a.xy;
        vec2 n = a.xy / 10.0;
        float z = sqrt(max(0.0, 1.0 - dot(n, n)));
        float l = clamp(dot(vec3(n, z), normalize(vec3(-0.5, -0.62, 0.6))), 0.0, 1.0);
        size = mix(0.3, 1.05, pow(l, 0.7));
        al = mix(0.45, 1.0, l) * beadIn;
      } else {
        q = a.xy;
        float r = length(a.xy), ang = atan(a.y, a.x);
        float off = delta(ang, bead);
        float d = abs(r - R);
        if (off < GAP) {
          vec2 e1 = R * vec2(cos(bead + GAP), sin(bead + GAP));
          vec2 e2 = R * vec2(cos(bead - GAP), sin(bead - GAP));
          d = min(distance(a.xy, e1), distance(a.xy, e2));
        }
        float gone = mod(ang - REST, TAU);
        float drawn = 1.0 - smoothstep(sweep - 0.14, sweep + 0.02, gone);
        float band = (1.0 - smoothstep(1.5, 2.5, d)) * drawn;
        float skirt = exp(-pow(max(d - 1.6, 0.0) / 8.0, 2.0)) * drawn;
        float clear = smoothstep(11.0, 13.0, distance(a.xy, b));
        float dust = 0.15 * (1.0 - smoothstep(106.0, 134.0, r)) * smoothstep(66.0, 88.0, r);
        float outer = (1.0 - smoothstep(0.3, 0.55, abs(r - 120.0))) * 0.2;
        size = max(0.0, dust + outer + 0.22 * skirt + 0.54 * band) * clear;
        al = mix(0.5, 1.0, max(band, skirt * 0.6));
      }
      vec2 dq = q - ptr;
      float f = exp(-dot(dq, dq) / 300.0) * press;
      q += normalize(dq + 0.0001) * f * 5.0;
      size *= 1.0 - 0.45 * f;
      gl_Position = vec4(q * scale * 2.0 / res * vec2(1.0, -1.0), 0.0, 1.0);
      gl_PointSize = max(size * scale * 1.12 * dpr, 0.0);
      col = vec4(vec3(al), al);
      if (size < 0.02) gl_Position = vec4(2.0);
    }`;
  const FS = `
    precision mediump float;
    varying vec4 col;
    void main() {
      float d = length(gl_PointCoord - 0.5) * 2.0;
      gl_FragColor = col * (1.0 - smoothstep(0.7, 1.0, d));
    }`;
  const shader = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const prog = gl.createProgram();
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { canvas.remove(); return; }
  gl.useProgram(prog);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

  // Polar tracks for the ring, a hex grid for the bead.
  const pts = [];
  for (let r = 64, t = 0; r < FIELD; r += 1, t++) {
    const n = Math.round(TAU * r);
    for (let i = 0; i < n; i++) {
      const th = ((i + (t % 2) * 0.5) / n) * TAU;
      pts.push(r * Math.cos(th), r * Math.sin(th), 0);
    }
  }
  const HEX = 0.92;
  for (let y = -10; y <= 10; y += HEX * 0.866) {
    const row = Math.round(y / (HEX * 0.866));
    for (let x = -10; x <= 10; x += HEX) {
      const px = x + (row % 2 ? HEX / 2 : 0);
      if (px * px + y * y < 100) pts.push(px, y, 1);
    }
  }
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(pts), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'a');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 3, gl.FLOAT, false, 0, 0);
  const COUNT = pts.length / 3;
  const u = {};
  for (const n of ['scale', 'dpr', 'bead', 'sweep', 'beadIn', 'press', 'ptr', 'res']) u[n] = gl.getUniformLocation(prog, n);

  let scale = 1;
  const layout = () => {
    // The ring clears the corners of the panel, whatever size the panel is showing at.
    const w = panel.getBoundingClientRect().width;
    scale = (w * 0.79) / 100;
    const size = Math.round(FIELD * 2 * scale);
    const dpr = Math.min(devicePixelRatio || 1, 2);
    canvas.style.width = canvas.style.height = `${size}px`;
    canvas.width = canvas.height = Math.round(size * dpr);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(u.res, size, size);
    gl.uniform1f(u.scale, scale);
    gl.uniform1f(u.dpr, dpr);
    dirty();
  };

  const state = { bead: REST, vel: 0, target: REST, sweep: TAU + 0.3, beadIn: 1, press: 0, pressTo: 0, ptrX: 9999, ptrY: 9999 };
  let raf = 0, intro = null;
  const draw = () => {
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform1f(u.bead, state.bead);
    gl.uniform1f(u.sweep, state.sweep);
    gl.uniform1f(u.beadIn, state.beadIn);
    gl.uniform1f(u.press, state.press);
    gl.uniform2f(u.ptr, state.ptrX, state.ptrY);
    gl.drawArrays(gl.POINTS, 0, COUNT);
  };
  const short = (a) => { let d = (a + Math.PI) % TAU; if (d < 0) d += TAU; return d - Math.PI; };
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

  const STEP = TAU / 6;
  const spin = { on: false, free: false, vel: 0, t: 0, grab: 0 };
  const nearest = (a) => {
    let best = 'history', gap = 9;
    for (const id in STOPS) { const g = Math.abs(short((STOPS[id] * Math.PI) / 180 - a)); if (g < gap) { gap = g; best = id; } }
    return best;
  };
  let last = 0;
  const frame = (now) => {
    raf = 0;
    const dt = Math.min(100, last ? now - last : 16);
    last = now;
    let live = false;
    if (intro && now < intro.t0) {
      live = true;
    } else if (intro) {
      const p = Math.min(1, (now - intro.t0) / intro.ms);
      const e = ease(p);
      state.beadIn = Math.min(1, p * 10);
      state.sweep = e * (TAU + 0.3);
      state.bead = REST + e * TAU;
      if (p >= 1) { intro = null; state.bead = short(REST); }
      live = true;
    } else {
      if (spin.on || spin.free) {
        if (spin.free) {
          state.bead += spin.vel * dt;
          spin.vel *= Math.pow(0.9972, dt);
          if (Math.abs(spin.vel) < 0.0007) {
            spin.free = false;
            state.vel = spin.vel * 16;
            const id = nearest(state.bead);
            panelTour.elapsed = 0;
            panelTour.holdUntil = now + HOLD;
            if (id !== panelTour.current) panel.show(id);
          }
          live = true;
        }
        const id = nearest(state.bead);
        if (id !== panelTour.current) panel.show(id, 'spin');
      }
      if (!spin.on && !spin.free) {
      panelTour.tick(dt, now);
      if (panelTour.active(now)) live = true;
      state.target = (STOPS[panelTour.current] * Math.PI) / 180 + STEP * (panelTour.elapsed / DWELL);
      const d = short(state.target - state.bead);
      state.vel = (state.vel + d * 0.016) * 0.88;
      state.bead += state.vel;
      if (Math.abs(d) > 0.0006 || Math.abs(state.vel) > 0.0006) live = true;
      else { state.bead = state.target; state.vel = 0; }
      }
    }
    const dp = state.pressTo - state.press;
    state.press += dp * 0.14;
    if (Math.abs(dp) > 0.004) live = true; else state.press = state.pressTo;
    draw();
    if (live) raf = requestAnimationFrame(frame); else last = 0;
  };
  function dirty() { if (!raf) raf = requestAnimationFrame(frame); }

  panel.addEventListener('real:change', ({ detail: { id } }) => {
    if (reduce) { state.bead = (STOPS[id] * Math.PI) / 180; state.vel = 0; }
    dirty();
  });
  // The drawing loop sleeps when nothing moves. This wakes it when the tabs are due to go on again.
  if (!reduce) setInterval(() => { if (panelTour.active(performance.now())) dirty(); }, 250);

  new ResizeObserver(layout).observe(panel);
  layout();

  if (!reduce) {
    state.sweep = 0;
    state.beadIn = 0;
    // The ring forms once the page shows (the script in the page head holds it until the opening is loaded).
    const begin = () => { intro = { t0: performance.now() + 300, ms: 2800 }; dirty(); };
    if (window.opened) window.opened.then(begin); else begin();
    dirty();
    const hero = document.querySelector('.hero');
    const units = (e) => {
      const box = canvas.getBoundingClientRect();
      return [(e.clientX - (box.left + box.width / 2)) / scale, (e.clientY - (box.top + box.height / 2)) / scale];
    };
    const onBall = (x, y) => Math.hypot(x - 100 * Math.cos(state.bead), y - 100 * Math.sin(state.bead)) < 15;
    hero.addEventListener('pointerdown', (e) => {
      if (intro || e.button || e.target.closest('a, button')) return;
      const [x, y] = units(e);
      if (!onBall(x, y)) return;
      e.preventDefault();
      hero.setPointerCapture(e.pointerId);
      spin.on = true; spin.free = false; spin.vel = 0; spin.t = e.timeStamp;
      spin.grab = short(state.bead - Math.atan2(y, x));
      panelTour.holdUntil = Infinity;
      hero.style.cursor = 'grabbing';
      dirty();
    });
    hero.addEventListener('pointermove', (e) => {
      if (!spin.on) {
        if (e.pointerType === 'mouse' && !intro) { const [x, y] = units(e); hero.style.cursor = onBall(x, y) ? 'grab' : ''; }
        return;
      }
      const [x, y] = units(e);
      const d = short(Math.atan2(y, x) + spin.grab - state.bead);
      const ms = Math.max(1, e.timeStamp - spin.t);
      spin.vel = spin.vel * 0.6 + (d / ms) * 0.4;
      spin.t = e.timeStamp;
      state.bead += d;
      dirty();
    });
    const release = (e) => {
      if (!spin.on) return;
      spin.on = false;
      spin.free = true;
      // A pause before letting go means it was put down, not thrown.
      if (e.timeStamp - spin.t > 80) spin.vel = 0;
      spin.vel = Math.max(-0.03, Math.min(0.03, spin.vel));
      hero.style.cursor = '';
      dirty();
    };
    hero.addEventListener('pointerup', release);
    hero.addEventListener('pointercancel', release);
    hero.addEventListener('pointermove', (e) => {
      if (e.pointerType !== 'mouse') return;
      const box = canvas.getBoundingClientRect();
      state.ptrX = (e.clientX - (box.left + box.width / 2)) / scale;
      state.ptrY = (e.clientY - (box.top + box.height / 2)) / scale;
      state.pressTo = 1;
      dirty();
    });
    hero.addEventListener('pointerleave', () => { state.pressTo = 0; dirty(); });
  }
})();
