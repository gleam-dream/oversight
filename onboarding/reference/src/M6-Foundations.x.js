  extraState() { return { lvRate: 6, lvPaused: false }; }
  lvInit() { this.lv = { t: 0, next: 0, toks: [], buf: [], obs: null, id: 0, emitted: 0, delivered: 0, dropped: 0, blocked: 0, prodBusy: null, els: {}, svg: null, inject: 0 }; }
  liveFrame(dt) { if (!this.lv) this.lvInit(); if (!this.state.lvPaused) this.lvSim(dt); this.lvDraw(); }
  lvSim(dt) {
    const L = this.lv, inline = this.state.route === 'inline', S = this.state.slow ? 0.5 : 0.05, CAP = 12, T1 = 0.35, T2 = 0.3;
    L.t += dt;
    const emit = () => { L.toks.push({ id: ++L.id, st: inline ? 'direct' : 'tofwd', t0: L.t }); L.emitted++; if (inline) L.prodBusy = L.id; };
    if (inline) {
      if (L.prodBusy) L.blocked += dt;
      if (!L.prodBusy && (L.inject > 0 || L.t >= L.next)) { if (L.inject > 0) L.inject--; else L.next = L.t + 1 / this.state.lvRate; emit(); }
    } else {
      while (L.inject > 0) { L.inject--; emit(); }
      if (L.t >= L.next) { emit(); L.next = L.t + 1 / this.state.lvRate; }
    }
    for (const k of L.toks) {
      if (k.st === 'direct' && L.t - k.t0 >= T1) { k.st = 'obsq'; }
      else if (k.st === 'tofwd' && L.t - k.t0 >= T2) { if (L.buf.length >= CAP) { k.st = 'drop'; k.t0 = L.t; L.dropped++; } else { k.st = 'buf'; L.buf.push(k); } }
      else if (k.st === 'toobs' && L.t - k.t0 >= T2) { k.st = 'obsq'; }
    }
    if (!L.obs) {
      const ready = L.toks.find((k) => k.st === 'obsq');
      if (ready) { ready.st = 'work'; ready.ws = L.t; L.obs = ready; }
      else if (!inline && L.buf.length && !L.toks.some((k) => k.st === 'toobs')) { const k = L.buf.shift(); k.st = 'toobs'; k.t0 = L.t; }
    }
    if (L.obs && L.t - L.obs.ws >= S) { const k = L.obs; k.st = 'done'; k.t0 = L.t; L.delivered++; L.obs = null; if (L.prodBusy === k.id) L.prodBusy = null; }
    L.toks = L.toks.filter((k) => !((k.st === 'done' && L.t - k.t0 > 0.3) || (k.st === 'drop' && L.t - k.t0 > 0.9)));
  }
  lvDraw() {
    const host = document.querySelector('#view [data-live="sinal"]'); if (!host) return;
    const L = this.lv, G = GD.svg, inline = this.state.route === 'inline';
    if (!L.svg || !host.contains(L.svg)) {
      host.innerHTML = ''; L.els = {};
      const svg = G('svg', { viewBox: '0 0 860 220', width: '100%', role: 'img', 'aria-label': 'Animation of telemetry events flowing from a request handler to observers, inline or through a bounded forwarder' }, host);
      svg.style.display = 'block'; svg.style.maxWidth = '860px'; svg.style.margin = '0 auto';
      L.pbox = G('rect', { x: 20, y: 40, width: 150, height: 110, rx: 14, fill: '#F6F4FF', stroke: '#DCD9FF', 'stroke-width': 2 }, svg);
      const a = G('text', { x: 95, y: 66, 'text-anchor': 'middle', 'font-size': 13, 'font-weight': 600, fill: '#17162B' }, svg); a.textContent = 'request handler';
      L.pstat = G('text', { x: 95, y: 128, 'text-anchor': 'middle', 'font-size': 11, fill: '#5B5970' }, svg);
      L.fwd = G('g', {}, svg);
      G('rect', { x: 330, y: 50, width: 250, height: 90, rx: 14, fill: '#EAF7F5', stroke: '#9FD6CF', 'stroke-width': 2 }, L.fwd);
      const f = G('text', { x: 455, y: 72, 'text-anchor': 'middle', 'font-size': 13, 'font-weight': 600, fill: '#0B4A45' }, L.fwd); f.textContent = 'forwarder · holds 12';
      for (let i = 0; i < 12; i++) G('rect', { x: 345 + i * 19, y: 86, width: 15, height: 30, rx: 4, fill: '#FFFFFF', stroke: '#C8E9E4' }, L.fwd);
      L.ftext = G('text', { x: 455, y: 134, 'text-anchor': 'middle', 'font-size': 11, fill: '#0B4A45' }, L.fwd);
      G('rect', { x: 672, y: 40, width: 180, height: 110, rx: 14, fill: '#FFFFFF', stroke: '#E4E0D8', 'stroke-width': 2 }, svg);
      L.otitle = G('text', { x: 762, y: 66, 'text-anchor': 'middle', 'font-size': 13, 'font-weight': 600, fill: '#17162B' }, svg);
      G('rect', { x: 707, y: 118, width: 110, height: 8, rx: 4, fill: '#EDEFF3' }, svg);
      L.prog = G('rect', { x: 707, y: 118, width: 0, height: 8, rx: 4, fill: '#B42318' }, svg);
      L.where = G('text', { x: 762, y: 142, 'text-anchor': 'middle', 'font-size': 11, fill: '#5B5970' }, svg);
      L.stats = G('text', { x: 20, y: 200, 'font-size': 12, 'font-weight': 600, fill: '#17162B' }, svg);
      L.layer = G('g', {}, svg);
      L.svg = svg;
    }
    const slow = this.state.slow;
    L.fwd.setAttribute('opacity', inline ? 0.25 : 1);
    L.ftext.textContent = inline ? 'bypassed: observers run in the handler' : L.buf.length + ' queued' + (L.buf.length >= 12 ? ' · FULL: new events dropped' : '');
    L.otitle.textContent = slow ? 'slow observer · 500 ms' : 'fast observers';
    L.where.textContent = inline ? 'runs inside the handler process' : 'runs inside the forwarder process';
    const blockedNow = inline && L.prodBusy;
    L.pbox.setAttribute('stroke', blockedNow && slow ? '#B42318' : '#DCD9FF');
    L.pstat.textContent = blockedNow ? (slow ? 'BLOCKED on telemetry' : 'emitting') : 'serving requests';
    L.pstat.setAttribute('fill', blockedNow && slow ? '#B42318' : '#5B5970');
    L.prog.setAttribute('width', L.obs ? Math.min(110, ((L.t - L.obs.ws) / (slow ? 0.5 : 0.05)) * 110).toFixed(1) : 0);
    const seen = {};
    L.buf.forEach((k, i) => { k.bi = i; });
    for (const k of L.toks) {
      const p = (d) => Math.min(1, (L.t - k.t0) / d);
      let x, y = 101, fill = '#0F766E', op = 1;
      if (k.st === 'direct') { x = 170 + (690 - 170) * p(0.35); }
      else if (k.st === 'tofwd') { x = 170 + (340 - 170) * p(0.3); }
      else if (k.st === 'buf') { const tx = 352 + k.bi * 19; k.vx = k.vx == null ? tx : k.vx + (tx - k.vx) * 0.3; x = k.vx; }
      else if (k.st === 'toobs') { x = 580 + (690 - 580) * p(0.3); }
      else if (k.st === 'obsq') { x = 700; }
      else if (k.st === 'work') { x = 765; y = 94; fill = '#B42318'; }
      else if (k.st === 'drop') { const q = (L.t - k.t0); x = 336 - q * 20; y = 101 + q * q * 160; fill = '#B42318'; op = Math.max(0, 1 - q / 0.9); }
      else { x = 765; y = 94 - (L.t - k.t0) * 70; op = Math.max(0, 1 - (L.t - k.t0) / 0.3); }
      let c = L.els[k.id]; if (!c) c = L.els[k.id] = GD.svg('circle', { r: 6.5 }, L.layer);
      c.setAttribute('cx', x.toFixed(1)); c.setAttribute('cy', y.toFixed(1)); c.setAttribute('fill', fill); c.setAttribute('opacity', op.toFixed(2));
      seen[k.id] = 1;
    }
    for (const id in L.els) if (!seen[id]) { L.els[id].remove(); delete L.els[id]; }
    L.stats.textContent = 'emitted ' + L.emitted + ' · delivered ' + L.delivered + ' · dropped and counted ' + L.dropped + ' · handler blocked ' + L.blocked.toFixed(1) + ' s';
  }
  extraVals() {
    const st = this.state, inline = st.route === 'inline', slow = st.slow;
    const lvNote = inline
      ? (slow ? 'Inline with a slow observer: the handler can’t serve the next request until telemetry finishes. Requests asked for ' + st.lvRate + '/s; the handler now manages about 1 per second.' : 'Inline with fast observers: they run inside the handler before emit returns. Simple, and the right default when observers are cheap.')
      : (slow ? 'Routed: the handler hands events to the forwarder and carries on at full speed. The forwarder can’t keep up with a slow observer either, so once it holds 12 it drops new events and counts them. Best effort, by design.' : 'Routed with fast observers: the forwarder drains as fast as events arrive. Nothing waits and nothing drops.');
    return {
      lvRate: st.lvRate, lvSetRate: (e) => this.setState({ lvRate: Number(e && e.target ? e.target.value : e) }),
      lvPause: () => this.setState({ lvPaused: !st.lvPaused }), lvPauseLabel: st.lvPaused ? 'Resume' : 'Pause',
      lvReset: () => { this.lvInit(); this.setState({ lvPaused: false }); },
      lvBurst: () => { if (!this.lv) this.lvInit(); this.lv.inject += 30; if (!GD.motion()) { for (let i = 0; i < 20; i++) this.lvSim(0.05); this.lvDraw(); } },
      lvStep: () => { if (!this.lv) this.lvInit(); for (let i = 0; i < 20; i++) this.lvSim(0.05); this.lvDraw(); },
      noMotion: !GD.motion(), lvNote
    };
  }
  tourDefs() {
    const quick = () => { if (!GD.motion() && this.lv) { for (let i = 0; i < 40; i++) this.lvSim(0.05); this.lvDraw(); } };
    return {
      sinal: { reset: () => { this.lvInit(); this.setState({ route: 'inline', slow: false, lvRate: 6, lvPaused: false }); }, steps: [
        { t: 'Every request the handler finishes emits an event. Right now observers are fast and run inline, inside the handler. Each dot is one event.', a: () => { this.lvInit(); this.setState({ route: 'inline', slow: false, lvRate: 6 }); } },
        { t: 'Attach a slow observer (500 ms). The handler turns red: it can’t serve the next request until telemetry finishes. Throughput collapses to about 1 per second.', a: ($) => { if (!this.state.slow) $().toggleSlow(); quick(); }, ms: 6500 },
        { t: 'Route the events through a forwarder. The handler is free again: it drops each event into the forwarder and moves on.', a: ($) => { $().routes[1].pick(); quick(); }, ms: 6000 },
        { t: 'But the slow observer still drains only 2 per second. The forwarder fills to its limit, then new events fall off and are counted. Watch the red drops.', a: () => quick(), ms: 6000 },
        { t: 'A burst of 30 makes it obvious: bounded, best effort, never blocking the request.', a: ($) => $().lvBurst(), ms: 5000 },
        { t: 'Remove the slow observer and the queue drains in moments. Telemetry informs; it never decides. Your turn.', a: ($) => { if (this.state.slow) $().toggleSlow(); quick(); } }
      ] },
      codec: { reset: () => this.setState({ face: 'decode', dcase: 0 }), steps: [
        { t: 'One codec describes a User: name, age 0 to 150, optional email, and a role of admin or member.' },
        { t: 'Face one, encode: a Gleam value becomes JSON. The missing email is simply left out.', a: ($) => $().faces[0].pick() },
        { t: 'Face two, decode: valid JSON becomes a typed User value.', a: ($) => { $().faces[1].pick(); $().cases[0].pick(); } },
        { t: 'Age 200 is out of range: decoding fails with the exact path, $.age. Feed that straight back to a model.', a: ($) => $().cases[2].pick() },
        { t: 'Repeated keys in untrusted text are refused outright, so two systems can never disagree about which "name" counted.', a: ($) => $().cases[4].pick() },
        { t: 'Face three, schema: the same rules, published as JSON Schema. Explore the cases yourself.', a: ($) => $().faces[2].pick() }
      ] },
      anatomy: { reset: () => this.setState({ part: 1 }), steps: [
        { t: 'One HTTP Gun request passes through five parts. Follow it left to right.' },
        { t: 'Your process sends. Only the process that opened a streamed body may read it.', a: ($) => $().parts[0].pick() },
        { t: 'The client pool admits the request against your limits and leases a connection.', a: ($) => $().parts[1].pick() },
        { t: 'A short-lived body owner coordinates this one response: limits, deadlines, cancellation.', a: ($) => $().parts[2].pick() },
        { t: 'Gun speaks HTTP/1.1 and HTTP/2 underneath; optional recorders and Sinal see everything.', a: ($) => $().parts[3].pick() },
        { t: 'Click any part for the details.' }
      ] },
      dest: { reset: ($) => $().policies[0].pick(), steps: [
        { t: 'Before connecting, HTTP Gun checks where each address really resolves.' },
        { t: 'The default policy: public addresses only. A name that resolves to a private network or cloud metadata is refused.', a: ($) => $().policies[0].pick() },
        { t: 'RequireTls also refuses plaintext HTTP, even to public hosts.', a: ($) => $().policies[1].pick() },
        { t: 'Local tests opt into loopback explicitly. Nothing reaches localhost by accident. Try the policies yourself.', a: ($) => $().policies[2].pick() }
      ] }
    };
  }
