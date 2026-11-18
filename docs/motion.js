// Things that move by themselves while they're on screen, and stop when they aren't: the notch going through its moments,
// and the weather changing. Nothing here follows the scroll. Also the two apps that work on this page: Focus and Caffeine.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Runs `step` every `ms` while `el` is on screen, unless the pointer is over it or the tab is hidden.
  const every = (el, ms, step) => {
    let visible = false, hover = false, timer = 0;
    const stop = () => { clearInterval(timer); timer = 0; };
    const sync = () => {
      const go = visible && !hover && !document.hidden && !reduce;
      if (go && !timer) timer = setInterval(step, ms);
      if (!go) stop();
    };
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; sync(); }, { threshold: 0.3 }).observe(el);
    el.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { hover = true; sync(); } });
    el.addEventListener('pointerleave', () => { hover = false; sync(); });
    document.addEventListener('visibilitychange', sync);
    return () => { stop(); sync(); };   // restart the wait after someone stepped by hand
  };

  // ---- the bar: comes in once the opening's own nav has scrolled away ----
  const bar = document.querySelector('.nav');
  new IntersectionObserver(([e]) => bar.classList.toggle('show', !e.isIntersecting)).observe(document.querySelector('.topnav'));

  // ---- one notch, a day of moments ----
  const day = document.querySelector('.day');
  const screen = day.querySelector('.screen');
  const morph = day.querySelector('.morph');
  const shape = day.querySelector('.shape');
  const beats = [...day.querySelectorAll('.beats li')];

  const caps = {};
  const capture = (name, w, h, cls = '') => {
    if (caps[name]) return caps[name];
    const img = new Image(w, h);
    img.src = `img/${name}.webp`;
    img.alt = '';
    img.className = cls;
    morph.append(img);
    return (caps[name] = img);
  };
  const pill = capture('notch-lyrics', 272, 41, 'pill');
  for (const li of beats) li.img = capture(li.dataset.cap, +li.dataset.w, +li.dataset.h);

  let current = -1;
  const fit = () => {
    const d = beats[current].dataset;
    // True size wherever it fits. Only what's too wide for the screen is drawn smaller.
    morph.style.scale = Math.min(1, screen.clientWidth / (+d.w + 14)).toFixed(3);
  };
  const setBeat = (i) => {
    current = i;
    const li = beats[i], d = li.dataset;
    for (const b of beats) b.classList.toggle('on', b === li);
    for (const name in caps) caps[name].classList.toggle('on', caps[name] === li.img);
    pill.classList.toggle('on', 'pill' in d);
    shape.style.left = `${d.l}px`;
    shape.style.width = `${d.r - d.l}px`;
    shape.style.height = `${d.bh}px`;
    shape.style.borderRadius = `0 0 ${d.rad}px ${d.rad}px`;
    fit();
  };
  const next = () => setBeat((current + 1) % beats.length);
  setBeat(reduce ? beats.findIndex((b) => b.dataset.cap === 'notch-open-home') : 0);
  addEventListener('resize', fit);
  const restart = every(screen, 3400, next);
  day.querySelector('.next').addEventListener('click', () => { next(); restart(); });

  // ---- the weather ----
  const weather = document.querySelector('.weather');
  const skies = [...weather.querySelectorAll('.wxsky')];
  const cards = [...weather.querySelectorAll('.wxcards img')];
  let wx = 0;
  every(weather, 3800, () => {
    const was = cards[wx];
    wx = (wx + 1) % cards.length;
    skies.forEach((s, i) => s.classList.toggle('on', i === wx));
    was.classList.replace('on', 'was');
    cards[wx].classList.add('on');
    cards[wx].animate([{ opacity: 0 }, { opacity: 1 }], { duration: 800, easing: 'ease' }).onfinish = () => was.classList.remove('was');
  });

  // ---- the mark at the bottom of the page: the ring is the O, and it spans the page ----
  oxineDots(document.querySelector('.sign'), {
    home: true,
    plan: (w, _h, measure) => {
      const type = measure('xine', 500, -0.03);
      const gutter = Math.max(12, w * 0.018);
      const ringF = (type.cap / 100) * 1.04, gapF = 0.05;
      const size = (w - 2 * gutter) / (ringF + gapF + type.ink / 100);
      const outer = (ringF * size) / 2;
      const sw = size * 0.062;
      const R = outer - sw;
      const ball = R * 0.33;
      const skirt = Math.max(6, size * 0.03);
      const head = Math.max(0, R * 0.866 + ball - outer) + skirt * 1.2;
      const height = Math.round(outer * 2 + head);
      const baseline = height - 2;
      return {
        height, pitch: oxineDots.pitchFor(w), skirt, ball,
        ring: { x: gutter + outer, y: baseline - outer * 0.985, R, sw },
        glyphs: [{ text: 'xine', x: gutter + outer * 2 + gapF * size - (type.lead / 100) * size, y: baseline, size, weight: type.weight, tracking: type.tracking }],
      };
    },
  });

  // ---- the two ends of the page ----
  // The bounce is the browser's own. Chrome on a Mac leaves fixed elements where they are while the page slides, so a sky behind the page (.past) stays in the gap. The page hides it the rest of the time.
  // Browsers that don't do that show the root's color past the edge, so that's matched to the sky at each end.
  const root = document.documentElement;
  const whichEnd = () => {
    const end = scrollY >= innerHeight;
    root.classList.toggle('at-end', end);
    root.style.backgroundColor = end ? '#103d65' : '#bf705b';
  };
  const fitSky = () => root.style.setProperty('--opening-sky', `${document.querySelector('.opening .sky').offsetHeight}px`);
  addEventListener('scroll', whichEnd, { passive: true });
  addEventListener('resize', fitSky);
  whichEnd();
  fitSky();

  // ---- two apps that work on this page ----
  // Focus dims the page itself.
  const focusTile = document.querySelector('.t-focus');
  const focusBtn = focusTile.querySelector('[data-toy="focus"]');
  const setFocus = (on) => {
    document.documentElement.classList.toggle('focusing', on);
    focusBtn.textContent = on ? 'Turn it off' : 'Try it on this page';
  };
  focusBtn.addEventListener('click', () => setFocus(!document.documentElement.classList.contains('focusing')));
  new IntersectionObserver(([e]) => { if (!e.isIntersecting) setFocus(false); }, { threshold: 0.1 }).observe(focusTile);

  // Caffeine asks the browser to keep the screen on.
  const awakeBtn = document.querySelector('[data-toy="caffeine"]');
  const awakeNote = document.querySelector('[data-toy-note="caffeine"]');
  let lock = null, since = 0, tick = 0;
  const showAwake = () => {
    awakeBtn.textContent = lock ? 'Let it sleep' : 'Keep this screen awake';
    if (!lock) { awakeNote.textContent = ''; clearInterval(tick); return; }
    const s = Math.floor((Date.now() - since) / 1000);
    awakeNote.textContent = `Awake for ${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  };
  if ('wakeLock' in navigator) {
    awakeBtn.hidden = false;
    awakeBtn.addEventListener('click', async () => {
      if (lock) { await lock.release(); return; }
      try {
        lock = await navigator.wakeLock.request('screen');
        since = Date.now();
        tick = setInterval(showAwake, 1000);
        lock.addEventListener('release', () => { lock = null; showAwake(); });
        showAwake();
      } catch { awakeNote.textContent = 'Your browser said no.'; }
    });
  }
})();
