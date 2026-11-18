// The Oxine mark drawn big, in the same dots as the ring in the opening: a ring, its ball, and type beside it.
// The footer uses it for the word, the 404 for the number. The ball can be grabbed and thrown in both.
// It sits still until someone takes the ball.
//   oxineDots(host, { plan, stage, free, home, push, onCatch, onDrop })
// plan(width, height, measure) says where things go. `free` lets the ball come off the ring, `home` sends it back to the logo's spot, `push` moves the dots away from the pointer.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const TAU = Math.PI * 2;
  const REST = (-120 * Math.PI) / 180;   // where the logo has its ball
  const short = (a) => { a = (a + Math.PI) % TAU; if (a < 0) a += TAU; return a - Math.PI; };
  const clamp = (x, a, b) => Math.min(b, Math.max(a, x));

  const VS = `
    attribute vec4 a;      // x, y, how much of a letter is here, how near one is
    attribute float k;     // 0 letters, 1 ring, 2 ball
    uniform vec2 res, ptr, ring, ball;
    uniform float R, sw, skirt, rb, dpr, p, press, ripple, phase, flash, roll, gap;
    varying float al;
    const float TAU = 6.2831853, GAPW = 0.4363323;
    float delta(float x, float y) { return abs(mod(x - y + TAU * 0.5, TAU) - TAU * 0.5); }
    void main() {
      vec2 q; float size; float alpha;
      if (k > 1.5) {
        float c = cos(roll), s = sin(roll);
        vec2 n = vec2(c * a.x - s * a.y, s * a.x + c * a.y);
        float z = sqrt(max(0.0, 1.0 - dot(n, n)));
        float l = clamp(dot(vec3(n, z), normalize(vec3(-0.5, -0.62, 0.6))), 0.0, 1.0);
        q = ball + n * rb;
        size = mix(0.3, 1.05, pow(l, 0.7)) * p * 1.12;
        alpha = mix(0.45, 1.0, l);
      } else {
        q = a.xy;
        float band, halo;
        if (k > 0.5) {
          vec2 rel = a.xy - ring;
          float r = length(rel), ang = atan(rel.y, rel.x);
          float d = abs(r - R);
          if (delta(ang, gap) < GAPW) {
            vec2 e1 = ring + R * vec2(cos(gap + GAPW), sin(gap + GAPW));
            vec2 e2 = ring + R * vec2(cos(gap - GAPW), sin(gap - GAPW));
            d = min(distance(a.xy, e1), distance(a.xy, e2));
          }
          band = 1.0 - smoothstep(sw - p * 0.5, sw + p * 0.5, d);
          halo = exp(-pow(max(d - sw, 0.0) / skirt, 2.0));
        } else {
          band = smoothstep(0.12, 0.72, a.z);
          halo = a.w;
        }
        size = (0.92 * band + 0.27 * halo * (1.0 - band)) * p;
        alpha = mix(0.5, 1.0, max(band, halo * 0.6));
        size *= smoothstep(rb + p * 0.6, rb + p * 1.8, distance(a.xy, ball));
        vec2 from = q - ring;
        float dist = max(length(from), 1.0);
        q += from / dist * ripple * sin(dist * 0.03 - phase) * exp(-dist / (res.x * 0.42));
        vec2 dq = q - ptr;
        float f = exp(-dot(dq, dq) / 2600.0) * press;
        q += normalize(dq + 0.0001) * f * p * 4.0;
        size *= (1.0 - 0.4 * f) * (1.0 + flash * 0.24);
      }
      gl_Position = size < 0.3 ? vec4(2.0) : vec4(q.x / res.x * 2.0 - 1.0, 1.0 - q.y / res.y * 2.0, 0.0, 1.0);
      gl_PointSize = size * dpr;
      al = alpha;
    }`;
  const FS = `
    precision mediump float;
    varying float al;
    void main() {
      float d = length(gl_PointCoord - 0.5) * 2.0;
      gl_FragColor = vec4(al) * (1.0 - smoothstep(0.7, 1.0, d));
    }`;

  // Widths and heights at 100px. Letters are placed one by one so the tracking is the same in every browser.
  const probe = document.createElement('canvas').getContext('2d');
  const fontAt = (size, weight) => `${weight} expanded ${size}px "Mona Sans", sans-serif`;
  const measure = (text, weight = 500, tracking = 0) => {
    probe.font = fontAt(100, weight);
    let w = 0;
    for (const ch of text) w += probe.measureText(ch).width + tracking * 100;
    w -= tracking * 100;
    const first = probe.measureText(text[0]), final = probe.measureText(text[text.length - 1]);
    const lead = -first.actualBoundingBoxLeft, trail = final.width - final.actualBoundingBoxRight;   // the blank space inside the first and last letters
    return { w, ink: w - lead - trail, lead, cap: probe.measureText('H').actualBoundingBoxAscent, weight, tracking };
  };

  // How far apart the dots are. On a 1x screen they have to stay apart by whole pixels or they turn to moire.
  const pitchFor = (w) => Math.max(devicePixelRatio >= 1.5 ? 2.1 : 3.4, Math.min(5, w / 410));

  window.oxineDots = (host, opts) => {
    const { plan, stage = host, free = false, home = false, push = false, onCatch = () => {}, onDrop = () => {} } = opts;
    const canvas = host.querySelector('canvas');
    const gl = canvas.getContext('webgl', { alpha: true, antialias: false, premultipliedAlpha: true });
    if (!gl) return null;
    const shader = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
    gl.useProgram(prog);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0, 0, 0, 0);
    const u = {};
    for (const n of ['res', 'ptr', 'ring', 'ball', 'R', 'sw', 'skirt', 'rb', 'dpr', 'p', 'press', 'ripple', 'phase', 'flash', 'roll', 'gap']) u[n] = gl.getUniformLocation(prog, n);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    const aA = gl.getAttribLocation(prog, 'a'), aK = gl.getAttribLocation(prog, 'k');
    gl.enableVertexAttribArray(aA);
    gl.enableVertexAttribArray(aK);
    gl.vertexAttribPointer(aA, 4, gl.FLOAT, false, 20, 0);
    gl.vertexAttribPointer(aK, 1, gl.FLOAT, false, 20, 16);

    const s = {
      mode: 'ring', a: REST, gap: REST, av: 0, hv: 0, homing: false,
      x: 0, y: 0, vx: 0, vy: 0, roll: 0, still: 0, asleep: false, armed: false, noCatch: 0, ox: 0, oy: 0,
      grab: 0, gx: 0, gy: 0, t: 0, press: 0, pressTo: 0, px: -9999, py: -9999,
      ripple: 0, phase: 0, flash: 0, slipAt: 0,
    };
    let P = null, W = 0, H = 0, count = 0, solid = null, cols = 0, rows = 0, cell = 1, visible = false, raf = 0, last = 0;

    const ballAt = () => (s.mode === 'ring' || s.mode === 'heldring')
      ? [P.ring.x + P.ring.R * Math.cos(s.a) + s.ox, P.ring.y + P.ring.R * Math.sin(s.a) + s.oy]
      : [s.x, s.y];

    const build = () => {
      const w = host.clientWidth;
      P = plan(w, host.clientHeight, measure);
      W = w; H = (P.height ?? host.clientHeight) + (P.below ?? 0);
      if (P.height) { host.style.height = `${P.height}px`; canvas.style.height = `${H}px`; }
      const dpr = Math.min(devicePixelRatio || 1, 2);
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      gl.viewport(0, 0, canvas.width, canvas.height);

      const p = P.pitch;
      const rw = Math.ceil(W), rh = Math.ceil(H);
      const off = document.createElement('canvas');
      off.width = rw; off.height = rh;
      const c = off.getContext('2d', { willReadFrequently: true });
      c.fillStyle = '#fff'; c.textBaseline = 'alphabetic';
      for (const g of P.glyphs) {
        c.font = fontAt(g.size, g.weight ?? 500);
        let x = g.x;
        for (const ch of g.text) { c.fillText(ch, x, g.y); x += c.measureText(ch).width + (g.tracking ?? 0) * g.size; }
      }
      const data = c.getImageData(0, 0, rw, rh).data;
      const at = (x, y) => (x < 0 || y < 0 || x >= rw || y >= rh ? 0 : data[((y | 0) * rw + (x | 0)) * 4 + 3] / 255);

      // A coarse copy: what the ball bounces off, and when blurred, the soft dots around each letter.
      cell = Math.max(2, p); cols = Math.ceil(W / cell) + 1; rows = Math.ceil(H / cell) + 1;
      solid = new Float32Array(cols * rows);
      for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
        let sum = 0;
        for (let m = 0; m < 3; m++) for (let n = 0; n < 3; n++) sum += at((i + m / 3) * cell, (j + n / 3) * cell);
        solid[j * cols + i] = sum / 9;
      }
      const soft = solid.slice(), tmp = new Float32Array(soft.length);
      const reach = Math.max(1, Math.round(P.skirt / cell / 1.6));
      for (let pass = 0; pass < 3; pass++) {
        for (let j = 0; j < rows; j++) { let sum = 0; for (let i = -reach; i < cols; i++) { if (i + reach < cols) sum += soft[j * cols + i + reach]; if (i - reach - 1 >= 0) sum -= soft[j * cols + i - reach - 1]; if (i >= 0) tmp[j * cols + i] = sum / (2 * reach + 1); } }
        for (let i = 0; i < cols; i++) { let sum = 0; for (let j = -reach; j < rows; j++) { if (j + reach < rows) sum += tmp[(j + reach) * cols + i]; if (j - reach - 1 >= 0) sum -= tmp[(j - reach - 1) * cols + i]; if (j >= 0) soft[j * cols + i] = sum / (2 * reach + 1); } }
      }
      const pts = [];
      const rowH = p * 0.866;
      for (let j = 0, y = 0; y < H; j++, y += rowH) for (let x = (j % 2) * p * 0.5; x < W; x += p) {
        const halo = Math.min(1, soft[(y / cell | 0) * cols + (x / cell | 0)] * 1.6);
        const q = p * 0.34;
        const cover = (at(x, y) * 2 + at(x - q, y) + at(x + q, y) + at(x, y - q) + at(x, y + q)) / 6;
        if (cover < 0.04 && halo < 0.05) continue;
        pts.push(x, y, cover, halo, 0);
      }
      const { x: cx, y: cy, R, sw } = P.ring;
      for (let r = R - sw - P.skirt * 1.7; r < R + sw + P.skirt * 1.7; r += p) {
        if (r <= 0) continue;
        const n = Math.round((TAU * r) / p);
        for (let i = 0; i < n; i++) {
          const th = ((i + (Math.round(r / p) % 2) * 0.5) / n) * TAU;
          pts.push(cx + r * Math.cos(th), cy + r * Math.sin(th), 0, 0, 1);
        }
      }
      const hp = (p * 0.9) / P.ball;
      for (let y = -1; y <= 1; y += hp * 0.866) {
        const row = Math.round(y / (hp * 0.866));
        for (let x = -1; x <= 1; x += hp) {
          const hx = x + (row % 2 ? hp / 2 : 0);
          if (hx * hx + y * y <= 1) pts.push(hx, y, 0, 0, 2);
        }
      }
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(pts), gl.STATIC_DRAW);
      count = pts.length / 5;
      if (s.mode === 'free' || s.mode === 'held') {
        s.x = clamp(s.x, P.ball, W - P.ball);
        s.y = clamp(s.y, P.ball, P.floor - P.ball);
        s.asleep = false;
      }
      gl.uniform2f(u.res, W, H);
      gl.uniform2f(u.ring, cx, cy);
      gl.uniform1f(u.R, R); gl.uniform1f(u.sw, sw); gl.uniform1f(u.skirt, P.skirt); gl.uniform1f(u.rb, P.ball);
      gl.uniform1f(u.dpr, dpr); gl.uniform1f(u.p, p);
    };

    const draw = () => {
      const [bx, by] = ballAt();
      gl.uniform2f(u.ball, bx, by);
      gl.uniform2f(u.ptr, s.px, s.py);
      gl.uniform1f(u.press, s.press);
      gl.uniform1f(u.ripple, s.ripple); gl.uniform1f(u.phase, s.phase); gl.uniform1f(u.flash, s.flash);
      gl.uniform1f(u.roll, s.roll); gl.uniform1f(u.gap, s.gap);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.POINTS, 0, count);
    };

    const solidAt = (x, y) => (x < 0 || y < 0 || x >= W || y >= H ? 0 : solid[(y / cell | 0) * cols + (x / cell | 0)]);

    // The ball against the big letters: find which edge of it is inside one, and send it the other way.
    const bounceOffLetters = () => {
      const rb = P.ball;
      for (let it = 0; it < 3; it++) {
        let nx = 0, ny = 0, hits = 0;
        for (let i = 0; i < 16; i++) {
          const th = (i / 16) * TAU, c = Math.cos(th), d = Math.sin(th);
          if (solidAt(s.x + c * rb, s.y + d * rb) > 0.5) { nx -= c; ny -= d; hits++; }
        }
        if (!hits) return;
        let len = Math.hypot(nx, ny);
        if (len < 0.01) { nx = 0; ny = -1; len = 1; }
        nx /= len; ny /= len;
        s.x += nx * 1.8; s.y += ny * 1.8;
        const vn = s.vx * nx + s.vy * ny;
        if (vn < 0) { const b = vn < -90 ? 1.55 : 1; s.vx -= b * vn * nx; s.vy -= b * vn * ny; }
        s.armed = true;
      }
    };

    const catchBall = (now) => {
      const { x: cx, y: cy, R } = P.ring;
      const th = Math.atan2(s.y - cy, s.x - cx);
      const vt = -s.vx * Math.sin(th) + s.vy * Math.cos(th);
      s.ox = s.x - (cx + R * Math.cos(th)); s.oy = s.y - (cy + R * Math.sin(th));
      s.a = th;
      s.av = clamp(vt / R / 1000, -0.03, 0.03);
      s.mode = 'ring'; s.asleep = false; s.flash = 1; s.ripple = Math.max(s.ripple, P.pitch * 4);
      onCatch();
    };

    const fall = () => {
      const { x: cx, y: cy, R } = P.ring;
      s.x = cx + R * Math.cos(s.a); s.y = cy + R * Math.sin(s.a);
      s.vx = -70; s.vy = -160; s.mode = 'free'; s.armed = false; s.still = 0; s.asleep = false;
      onDrop();
    };

    const step = (ms, now) => {
      let live = false;
      if (s.mode === 'ring') {
        if (s.av) {
          s.a += s.av * ms;
          s.av *= Math.pow(0.9972, ms);
          if (Math.abs(s.av) < 0.0007) { s.av = 0; s.homing = home; s.hv = 0; }
          live = true;
        }
        if (s.homing) {
          const d = short(REST - s.a), f = ms / 16;
          s.hv = (s.hv + d * 0.014 * f) * Math.pow(0.88, f);
          s.a += s.hv * f;
          if (Math.abs(d) < 0.0006 && Math.abs(s.hv) < 0.0006) { s.a = REST; s.hv = 0; s.homing = false; } else live = true;
        }
        if (s.slipAt) {
          if (now >= s.slipAt) { s.slipAt = 0; fall(); }
          live = true;
        }
      } else if (s.mode === 'free' && !s.asleep) {
        const rb = P.ball, F = P.floor, x0 = s.x, y0 = s.y;
        if (reduce) {
          s.y = F - rb; s.vx = s.vy = 0; s.asleep = true;
          if (s.armed && now >= s.noCatch && Math.abs(Math.hypot(x0 - P.ring.x, y0 - P.ring.y) - P.ring.R) < P.ring.sw + rb) { s.x = x0; s.y = y0; catchBall(now); }
          live = true;
        } else {
          const n = 3, h = ms / 1000 / n;
          for (let i = 0; i < n && s.mode === 'free'; i++) {
            s.vy += P.gravity * h;
            s.x += s.vx * h; s.y += s.vy * h;
            if (s.x < rb) { s.x = rb; s.vx = Math.abs(s.vx) * 0.7; }
            if (s.x > W - rb) { s.x = W - rb; s.vx = -Math.abs(s.vx) * 0.7; }
            if (s.y < rb) { s.y = rb; s.vy = Math.abs(s.vy) * 0.5; }
            if (s.y > F - rb) {
              s.y = F - rb;
              s.vy = s.vy > 90 ? -s.vy * 0.62 : 0;
              s.vx *= Math.pow(0.28, h);
              s.armed = true;
            }
            bounceOffLetters();
            if (s.armed && now >= s.noCatch && Math.abs(Math.hypot(s.x - P.ring.x, s.y - P.ring.y) - P.ring.R) < P.ring.sw + rb * 0.3) catchBall(now);
          }
          if (s.mode === 'free') {
            s.roll += ((s.x - x0) / rb);
            s.still = Math.hypot(s.x - x0, s.y - y0) < 0.5 ? s.still + ms : 0;
            if (s.still > 500) { s.asleep = true; s.vx = s.vy = 0; }
          }
          live = true;
        }
      } else if (s.mode === 'held' || s.mode === 'heldring') {
        live = true;
      }
      if (s.mode === 'ring' || s.mode === 'heldring') {
        const off = short(s.a - s.gap);
        s.gap += off * Math.min(1, ms * 0.02);
        if (Math.abs(off) > 0.001) live = true; else s.gap = s.a;
        s.ox *= Math.pow(0.97, ms); s.oy *= Math.pow(0.97, ms);
        if (Math.abs(s.ox) + Math.abs(s.oy) > 0.1) live = true; else s.ox = s.oy = 0;
      }
      const wants = reduce ? 0 : Math.min(P.pitch * 4, Math.abs(s.av) * 500);
      s.ripple += (wants - s.ripple) * Math.min(1, ms * 0.006);
      s.phase += ms * 0.012;
      if (s.ripple > 0.05) live = true; else s.ripple = 0;
      s.flash *= Math.pow(0.992, ms);
      if (s.flash > 0.01) live = true; else s.flash = 0;
      const dp = s.pressTo - s.press;
      s.press += dp * Math.min(1, ms * 0.009);
      if (Math.abs(dp) > 0.004) live = true; else s.press = s.pressTo;
      return live;
    };

    const frame = (now) => {
      raf = 0;
      if (!visible) { last = 0; return; }
      const ms = Math.min(34, last ? now - last : 16);
      last = now;
      const live = step(ms, now);
      draw();
      if (live) raf = requestAnimationFrame(frame); else last = 0;
    };
    const wake = () => { if (!raf && visible) raf = requestAnimationFrame(frame); };

    const where = (e) => { const b = canvas.getBoundingClientRect(); return [e.clientX - b.left, e.clientY - b.top]; };
    const onBall = (x, y, wide) => { const [bx, by] = ballAt(); return Math.hypot(x - bx, y - by) < Math.max(P.ball * 1.05, wide ? 30 : 0); };
    let held = false;
    stage.addEventListener('pointerdown', (e) => {
      if (e.button || e.target.closest('a, button')) return;
      const [x, y] = where(e);
      if (!onBall(x, y, e.pointerType !== 'mouse')) return;
      e.preventDefault();
      stage.setPointerCapture(e.pointerId);
      held = true; s.slipAt = 0; s.t = e.timeStamp; s.homing = false;
      if (s.mode === 'ring') {
        s.mode = 'heldring'; s.av = 0;
        s.grab = short(s.a - Math.atan2(y - P.ring.y, x - P.ring.x));
      } else {
        s.mode = 'held'; s.gx = x - s.x; s.gy = y - s.y; s.vx = s.vy = 0; s.asleep = false;
      }
      stage.style.cursor = 'grabbing';
      wake();
    });
    // The ball's press on a touch screen shouldn't scroll the page.
    stage.addEventListener('touchstart', (e) => {
      if (e.target.closest('a, button')) return;
      const [x, y] = where(e.touches[0]);
      if (onBall(x, y, true)) e.preventDefault();
    }, { passive: false });
    stage.addEventListener('pointermove', (e) => {
      const [x, y] = where(e);
      if (e.pointerType === 'mouse') {
        if (push) { s.px = x; s.py = y; s.pressTo = reduce ? 0 : 1; wake(); }
        if (!held) stage.style.cursor = onBall(x, y) ? 'grab' : '';
      }
      if (!held) return;
      const ms = Math.max(1, e.timeStamp - s.t);
      s.t = e.timeStamp;
      const off = Math.hypot(x - P.ring.x, y - P.ring.y) - P.ring.R;
      if (s.mode === 'heldring') {
        const d = short(Math.atan2(y - P.ring.y, x - P.ring.x) + s.grab - s.a);
        s.av = s.av * 0.6 + (d / ms) * 0.4;
        s.a += d;
        if (free && Math.abs(off) > P.ring.sw + P.ball * 1.3) {
          s.mode = 'held'; s.x = x; s.y = y; s.gx = s.gy = 0; s.vx = s.vy = 0; s.av = 0;
          onDrop();
        }
      } else {
        const nx = x - s.gx, ny = y - s.gy;
        s.vx = s.vx * 0.6 + ((nx - s.x) / ms) * 1000 * 0.4;
        s.vy = s.vy * 0.6 + ((ny - s.y) / ms) * 1000 * 0.4;
        s.x = nx; s.y = ny;
        if (Math.abs(off) < P.ring.sw * 0.8) {
          s.a = Math.atan2(ny - P.ring.y, nx - P.ring.x);
          s.ox = s.oy = 0; s.grab = 0; s.av = 0; s.mode = 'heldring'; s.flash = 1;
          onCatch();
        }
      }
      wake();
    });
    const release = (e) => {
      if (!held) return;
      held = false;
      const paused = e.timeStamp - s.t > 80;     // a pause before letting go means it was put down, not thrown
      if (s.mode === 'heldring') {
        s.av = paused ? 0 : clamp(s.av, -0.03, 0.03);
        s.mode = 'ring';
        if (home && !s.av) s.homing = true;
      } else {
        s.vx = paused ? 0 : clamp(s.vx, -3400, 3400);
        s.vy = paused ? 0 : clamp(s.vy, -3400, 3400);
        s.mode = 'free'; s.armed = true; s.still = 0; s.asleep = false; s.noCatch = 0;
      }
      stage.style.cursor = '';
      wake();
    };
    stage.addEventListener('pointerup', release);
    stage.addEventListener('pointercancel', release);
    if (push) stage.addEventListener('pointerleave', () => { s.pressTo = 0; wake(); });

    let width = -1, height = -1;
    const rebuild = () => {
      if (host.clientWidth === width && (P?.height || host.clientHeight === height)) return;
      width = host.clientWidth; height = host.clientHeight;
      build();
      draw();
      wake();
    };
    const start = () => {
      build();
      width = host.clientWidth; height = host.clientHeight;
      host.classList.add('on');
      if (free) {
        if (reduce) { s.mode = 'free'; s.x = P.ring.x + P.ring.R * 1.35; s.y = P.floor - P.ball; s.armed = true; s.asleep = true; s.gap = REST; onDrop(); }
        else s.slipAt = performance.now() + (opts.slipAfter ?? 1100);
      }
      new ResizeObserver(() => rebuild()).observe(host);
      draw();     // there before it's scrolled to; the loop only runs while it's on screen
      new IntersectionObserver(([e]) => {
        visible = e.isIntersecting;
        if (visible) wake();
      }).observe(host);
    };
    document.fonts.load(fontAt(100, 500), 'xine4H').then(start, start);
    return { state: s, ball: ballAt };
  };
  window.oxineDots.pitchFor = pitchFor;
})();
