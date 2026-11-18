// Makes real screenshots answer clicks: invisible buttons sit over the tabs in the picture and swap to the capture of that tab.
// Every picture is a capture of the app. Nothing here draws UI.
(() => {
  const IMG = new URL('../img/', document.currentScript.src).href;
  // Rects are x, y, w, h in the capture's points.
  const SETS = {
    panel: {
      w: 480, h: 560, file: (t) => `panel-${t}.webp`,
      tabs: {
        notes:   ['Notes',   [10, 6, 70, 34],  'The Notes tab: a writer at the top and notes as cards, one with a checklist.'],
        history: ['History', [80, 6, 86, 34],  'The History tab: a search box, filter chips and the things you copied, with secrets hidden under invisible ink.'],
        auth:    ['Auth',    [170, 6, 62, 34], 'The Auth tab: 2FA accounts, each with a six digit code and a countdown ring.'],
        scripts: ['Scripts', [238, 6, 76, 34], 'The Scripts tab: tiles for Base64 Encode, JSON Pretty, Slugify, Uppercase and Word Count.'],
        sous:    ['Sous',    [320, 6, 64, 34], 'The Sous tab: charging at 64 percent, a charge limit of 80, power flow and battery health.'],
        temper:  ['Temper',  [390, 6, 78, 34], 'The Temper tab: 52 degrees, running cool, thermal pressure, CPU load, fan control modes and fans.'],
      },
    },
  };
  const pct = (v, of) => `${(v / of) * 100}%`;

  document.querySelectorAll('.real[data-set]').forEach((box) => {
    const set = SETS[box.dataset.set];
    const base = box.querySelector('img');
    let current = box.dataset.start;
    const layers = {};
    const buttons = {};
    let settle;
    // mode: 'auto' for the timer (slow fade), 'spin' for the ball going past (quick). Nothing means someone picked it.
    const show = (id, mode) => {
      if (id === current) return;
      box.classList.toggle('slow', mode === 'auto');
      // The new capture fades in on top of the old one, which stays solid until it's covered.
      for (const k in layers) layers[k].style.zIndex = k === id ? 2 : k === current ? 1 : 0;
      layers[id].classList.add('on');
      clearTimeout(settle);
      settle = setTimeout(() => { for (const k in layers) if (k !== id) layers[k].classList.remove('on'); }, 700);
      current = id;
      for (const k in buttons) buttons[k].setAttribute('aria-pressed', String(k === id));
      base.alt = set.tabs[id][2];
      box.dispatchEvent(new CustomEvent('real:change', { detail: { id, auto: !!mode } }));
    };
    box.show = show;
    for (const id in set.tabs) {
      const [label, r] = set.tabs[id];
      if (r) {
        const b = document.createElement('button');
        b.type = 'button';
        b.setAttribute('aria-label', `Show ${label}`);
        b.setAttribute('aria-pressed', String(id === current));
        b.style.cssText = `left:${pct(r[0], set.w)};top:${pct(r[1], set.h)};width:${pct(r[2], set.w)};height:${pct(r[3], set.h)}`;
        b.addEventListener('click', () => show(id));
        box.append(b);
        buttons[id] = b;
      }
      const l = new Image(set.w, set.h);
      l.alt = '';
      l.className = 'layer' + (id === current ? ' on' : '');
      l.decoding = 'async';
      l.dataset.src = IMG + set.file(id);
      box.insertBefore(l, box.firstElementChild.nextSibling);
      layers[id] = l;
    }
    const load = () => { for (const k in layers) if (!layers[k].src) layers[k].src = layers[k].dataset.src; };
    box.addEventListener('pointerenter', load, { once: true });
    box.addEventListener('focusin', load, { once: true });
    (window.requestIdleCallback || setTimeout)(load);
  });

})();
