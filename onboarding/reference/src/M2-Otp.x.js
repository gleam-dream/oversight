
  extraState() { return { mbMode: 'send', mbRate: 6, mbPaused: false }; }
  mbInit() { this.mb = { t: 0, next: 0, toks: [], q: [], busy: null, callers: [0, 0, 0, 0], sent: 0, handled: 0, id: 0, els: {}, svg: null }; }
  liveFrame(dt) { if (!this.mb) this.mbInit(); if (!this.state.mbPaused) this.mbSim(dt); this.mbDraw(); }
  mbSim(dt) {
    const M = this.mb, S = 0.25, TRAVEL = 0.4, rate = this.state.mbRate, call = this.state.mbMode === 'call';
    M.t += dt;
    if (M.t >= M.next) {
      const free = M.callers.indexOf(0);
      if (!call || free >= 0) {
        const c = call ? free : M.sent % 4;
        if (call) M.callers[c] = 1;
        M.toks.push({ id: ++M.id, st: 'fly', t0: M.t, c, call });
        M.sent++; M.next = M.t + 1 / rate;
      } else M.next = M.t;
    }
    for (const k of M.toks) {
      if (k.st === 'fly' && M.t - k.t0 >= TRAVEL) { k.st = 'q'; k.qt = M.t; M.q.push(k); }
      else if (k.st === 'reply' && M.t - k.t0 >= TRAVEL) { k.st = 'gone'; M.callers[k.c] = 0; }
    }
    if (M.busy && M.t - M.busy.ws >= S) {
      const k = M.busy; M.handled++; M.busy = null;
      if (k.call) { k.st = 'reply'; k.t0 = M.t; } else { k.st = 'done'; k.t0 = M.t; }
    }
    if (!M.busy && M.q.length) { const k = M.q.shift(); k.st = 'work'; k.ws = M.t; M.busy = k; }
    M.toks = M.toks.filter((k) => k.st !== 'gone' && !(k.st === 'done' && M.t - k.t0 > 0.35));
  }
  mbDraw() {
    const host = document.querySelector('#view [data-live="mailbox"]'); if (!host) return;
    const M = this.mb, G = GD.svg;
    if (!M.svg || !host.contains(M.svg)) {
      host.innerHTML = ''; M.els = {};
      const svg = G('svg', { viewBox: '0 0 860 236', width: '100%', role: 'img', 'aria-label': 'Animation of messages flowing from four request processes into an actor mailbox' }, host);
      svg.style.display = 'block'; svg.style.maxWidth = '860px'; svg.style.margin = '0 auto';
      G('rect', { x: 20, y: 40, width: 150, height: 130, rx: 14, fill: '#F6F4FF', stroke: '#DCD9FF' }, svg);
      const t1 = G('text', { x: 95, y: 64, 'text-anchor': 'middle', 'font-size': 13, 'font-weight': 600, fill: '#17162B' }, svg); t1.textContent = '4 request processes';
      M.cdots = [0, 1, 2, 3].map((i) => G('circle', { cx: 50 + i * 30, cy: 96, r: 10, fill: '#FFFFFF', stroke: '#7C4DCC', 'stroke-width': 2 }, svg));
      M.pstat = G('text', { x: 95, y: 140, 'text-anchor': 'middle', 'font-size': 11, fill: '#5B5970' }, svg);
      G('line', { x1: 172, y1: 96, x2: 420, y2: 96, stroke: '#D5D1C8', 'stroke-width': 2, 'stroke-dasharray': '4 5' }, svg);
      const l1 = G('text', { x: 290, y: 84, 'text-anchor': 'middle', 'font-size': 11, fill: '#8A8698' }, svg); l1.textContent = 'messages →';
      M.rlane = G('line', { x1: 172, y1: 134, x2: 640, y2: 134, stroke: '#B9E2C4', 'stroke-width': 2, 'stroke-dasharray': '4 5' }, svg);
      M.rlab = G('text', { x: 400, y: 152, 'text-anchor': 'middle', 'font-size': 11, fill: '#15803D' }, svg); M.rlab.textContent = '← replies';
      G('rect', { x: 420, y: 78, width: 214, height: 36, rx: 8, fill: '#FFFFFF', stroke: '#DCD9FF' }, svg);
      const ml = G('text', { x: 420, y: 70, 'font-size': 11, fill: '#5B5970' }, svg); ml.textContent = 'mailbox';
      M.more = G('text', { x: 634, y: 70, 'text-anchor': 'end', 'font-size': 11, 'font-weight': 700, fill: '#B42318' }, svg);
      G('rect', { x: 650, y: 40, width: 190, height: 130, rx: 14, fill: '#FDF0DC', stroke: '#F3D9B1' }, svg);
      const al = G('text', { x: 745, y: 64, 'text-anchor': 'middle', 'font-size': 13, 'font-weight': 600, fill: '#17162B' }, svg); al.textContent = 'actor · 4 per second';
      G('rect', { x: 680, y: 122, width: 130, height: 8, rx: 4, fill: '#F3D9B1' }, svg);
      M.prog = G('rect', { x: 680, y: 122, width: 0, height: 8, rx: 4, fill: '#B45309' }, svg);
      M.mem = G('rect', { x: 420, y: 180, width: 0, height: 10, rx: 5, fill: '#B42318' }, svg);
      M.memt = G('text', { x: 420, y: 208, 'font-size': 11, fill: '#5B5970' }, svg);
      M.stats = G('text', { x: 20, y: 208, 'font-size': 12, 'font-weight': 600, fill: '#17162B' }, svg);
      M.layer = G('g', {}, svg);
      M.svg = svg;
    }
    const call = this.state.mbMode === 'call', TRAVEL = 0.4;
    M.cdots.forEach((d, i) => d.setAttribute('fill', call && M.callers[i] ? '#7C4DCC' : '#FFFFFF'));
    M.pstat.textContent = call ? (M.callers.every((c) => c) ? 'all 4 waiting for replies' : 'calling, then waiting') : 'sending, never waiting';
    M.rlane.setAttribute('opacity', call ? 1 : 0.15); M.rlab.setAttribute('opacity', call ? 1 : 0.15);
    const seen = {};
    const slotX = (k) => 622 - k * 19;
    M.q.forEach((k, i) => { k.qi = i; });
    for (const k of M.toks) {
      let x, y, fill = '#7C4DCC', op = 1;
      if (k.st === 'fly') { const p = Math.min(1, (M.t - k.t0) / TRAVEL); x = 50 + k.c * 30 + (Math.min(slotX(Math.min(M.q.length, 10)), 600) - 50 - k.c * 30) * p; y = 96; }
      else if (k.st === 'q') { if (k.qi > 10) continue; const tx = slotX(k.qi); k.vx = k.vx == null ? tx : k.vx + (tx - k.vx) * 0.25; x = k.vx; y = 96; }
      else if (k.st === 'work') { x = 745; y = 96; fill = '#B45309'; }
      else if (k.st === 'reply') { const p = Math.min(1, (M.t - k.t0) / TRAVEL); x = 745 - (745 - 50 - k.c * 30) * p; y = 134; fill = '#15803D'; }
      else { x = 745; y = 96 - (M.t - k.t0) * 60; fill = '#B45309'; op = Math.max(0, 1 - (M.t - k.t0) / 0.35); }
      let c = M.els[k.id]; if (!c) { c = M.els[k.id] = GD.svg('circle', { r: 7 }, M.layer); }
      c.setAttribute('cx', x.toFixed(1)); c.setAttribute('cy', y.toFixed(1)); c.setAttribute('fill', fill); c.setAttribute('opacity', op.toFixed(2));
      seen[k.id] = 1;
    }
    for (const id in M.els) if (!seen[id]) { M.els[id].remove(); delete M.els[id]; }
    M.more.textContent = M.q.length > 11 ? '+' + (M.q.length - 11) + ' more waiting' : '';
    M.prog.setAttribute('width', M.busy ? Math.min(130, ((M.t - M.busy.ws) / 0.25) * 130).toFixed(1) : 0);
    M.mem.setAttribute('width', Math.min(420, M.q.length * 3).toFixed(1));
    M.mem.setAttribute('fill', M.q.length > 20 ? '#B42318' : '#E0B000');
    M.memt.textContent = 'mailbox memory · ' + M.q.length + ' message' + (M.q.length === 1 ? '' : 's') + (M.q.length > 20 ? ' and climbing: no limit' : '');
    const oldest = M.q.length ? (M.t - M.q[0].qt).toFixed(1) : '0.0';
    M.stats.textContent = 'sent ' + M.sent + ' · handled ' + M.handled + ' · waiting ' + M.q.length + ' · oldest waited ' + oldest + ' s';
  }
  extraVals() {
    const ae = this.state.aev || [], te = this.state.tev || [];
    const st = this.state, over = st.mbRate > 4;
    const mbNote = st.mbMode === 'call'
      ? 'Call: each request process waits for its reply before sending again. However high you set the rate, they can never outrun the actor: its speed sets the pace and the mailbox stays short. That is backpressure, and it comes free with waiting.'
      : over ? 'Send at ' + st.mbRate + '/s into an actor that handles 4/s: the mailbox grows by about ' + (st.mbRate - 4) + ' messages every second, forever. Each message waits longer than the last and memory climbs until something gives. Nothing pushes back on a plain send.'
      : 'Send at ' + st.mbRate + '/s: the actor keeps up, so the mailbox stays near empty. Now push the rate above 4.';
    return {
      mbModes: [['send', 'Send (fire and forget)'], ['call', 'Call (wait for the reply)']].map((m) => ({ label: m[1], cls: st.mbMode === m[0] ? 'on' : '', pick: () => this.setState({ mbMode: m[0] }) })),
      mbRate: st.mbRate, mbSetRate: (e) => this.setState({ mbRate: Number(e && e.target ? e.target.value : e) }),
      mbPause: () => this.setState({ mbPaused: !st.mbPaused }), mbPauseLabel: st.mbPaused ? 'Resume' : 'Pause',
      mbReset: () => { this.mbInit(); this.setState({ mbPaused: false }); },
      mbStep: () => { if (!this.mb) this.mbInit(); for (let i = 0; i < 20; i++) this.mbSim(0.05); this.mbDraw(); },
      noMotion: !GD.motion(), mbNote,
      actorChart: GD.msc({ id: 'a2', lanes: ['request A', 'request B', 'cart actor'], events: ae, laneGap: 200, row: 34, numbers: true, aria: 'Sequence chart of requests arriving at the cart actor and its replies' }),
      treeChart: GD.msc({ id: 't2', lanes: ['supervisor', 'DB pool', 'HTTP client', 'Job runtime', 'Web server'], events: te.length ? te : [{ f: 0, kind: 'note', label: 'watching: crash a child to see signals here', color: 'grey' }], laneGap: 150, row: 27, numbers: true, aria: 'Sequence chart of exit signals and restarts in the supervision tree' })
    };
  }
  tourDefs() {
    const strat = ($, k) => $().strategies[k].pick();
    return {
      actor: { reset: ($) => $().resetActor(), steps: [
        { t: 'A cart actor: a mailbox of four messages, a handler, and private state. Messages are handled strictly one at a time.' },
        { t: 'Handle "add Book": the handler takes the message and the current state, and returns the next state. Version 1.', a: ($) => $().step() },
        { t: 'Handle "add Mug". A send expects no answer, so nothing goes back.', a: ($) => $().step() },
        { t: '"get total" is a call: the caller is waiting. The actor replies with €20 (the green dashed arrow) and its state doesn’t change.', a: ($) => $().step() },
        { t: 'Two requests arrive at the very same instant. No race, no lock: they simply queue up in the mailbox.', a: ($) => $().burst() },
        { t: 'The actor works through them in order. Request B gets its reply only after request A’s message is done.', a: ($) => { $().step(); $().step(); $().step(); } },
        { t: 'One process, one message at a time: that’s why actors need no locks. Now drive it yourself.' }
      ] },
      tree: { reset: ($) => $().resetTree(), steps: [
        { t: 'A shop service. The root supervisor started four children in order and watches all of them.' },
        { t: 'One-for-one strategy. Crash the HTTP client: the supervisor gets an EXIT signal and restarts only that child.', a: ($) => { strat($, 0); $().kids[1].crash(); }, ms: 4200 },
        { t: 'Rest-for-one: crash the HTTP client again. Everything started after it is stopped and restarted too, in the original order.', a: ($) => { strat($, 2); $().kids[1].crash(); }, ms: 4200 },
        { t: 'One-for-all: crash the job runtime. Every child restarts, because these children only make sense together.', a: ($) => { strat($, 1); $().kids[2].crash(); }, ms: 4200 },
        { t: 'Crash the database pool: that is a 4th crash within 5 seconds. Restarting clearly isn’t helping, so the supervisor stops every child, crashes itself and escalates to its parent.', a: ($) => $().kids[0].crash(), ms: 4200 },
        { t: 'Escalation is a feature: failure climbs the tree until a level that can handle it. Reset, and try your own crashes.' }
      ] },
      load: { reset: () => { this.mbInit(); this.setState({ mbMode: 'send', mbRate: 3, mbPaused: false }); }, steps: [
        { t: 'Four request processes send messages to one actor that can handle 4 per second. At 3 per second it keeps up easily.', a: () => { this.mbInit(); this.setState({ mbMode: 'send', mbRate: 3 }); } },
        { t: 'Raise the rate to 8 per second with plain sends. Watch the mailbox fill and the oldest message wait longer and longer.', a: () => this.setState({ mbRate: 8 }), ms: 7000 },
        { t: 'Still climbing. BEAM mailboxes have no limit, so a slow actor quietly eats memory until something breaks.', a: () => { if (!GD.motion()) this.__vals().mbStep(); }, ms: 5000 },
        { t: 'Switch to call: each request process now waits for its reply (green) before sending again. New sends slow to the actor’s pace and the backlog drains.', a: ($) => $().mbModes[1].pick(), ms: 8000 },
        { t: 'Waiting is backpressure. The libraries in this course make it explicit: bounded queues, pools and per-queue concurrency. Play with the rate yourself.' }
      ] },
      plug: { reset: () => this.setState({ plug: 0 }), steps: [
        { t: 'Your application’s root supervisor, with children that come from gleam-dream libraries.' },
        { t: 'HTTP Gun brings a pool process plus one short-lived process per open response.', a: () => this.setState({ plug: 0 }) },
        { t: 'Grind brings a coordinator per queue, an attempt process per job run, and a lease renewer.', a: () => this.setState({ plug: 2 }) },
        { t: 'Fabric brings a store that keeps run records and supervises runners.', a: () => this.setState({ plug: 4 }) },
        { t: 'Every library gives you children; you decide where they live in your tree. Click the others.' }
      ] }
    };
  }
