  extraState() { return { att: [], attBrk: -1, attKey: null, herd: 'imm', herdT: 999 }; }
  extraMount() { this.herdStart(); }
  extraUnmount() { clearInterval(this.herdTimer); }
  herdStart() {
    clearInterval(this.herdTimer);
    if (!GD.motion()) { this.setState({ herdT: 999 }); return; }
    this.setState({ herdT: 0 });
    this.herdTimer = setInterval(() => {
      if (this.state.herdT >= 75) { clearInterval(this.herdTimer); return; }
      this.setState({ herdT: this.state.herdT + 1 });
    }, 45);
  }
  herdSim(kind) {
    const rng = GD.rng(7), N = 80, CAP = 6, DOWN = 10, T = 75;
    const cl = []; for (let i = 0; i < N; i++) cl.push({ next: Math.floor(rng() * 3), att: 0, done: false });
    const ticks = []; let attempts = 0, rejected = 0, doneTick = -1, peak = 0;
    const exp = (c) => Math.min(4 * Math.pow(2, c.att - 1), 32);
    const delay = (c) => kind === 'imm' ? 1 : kind === 'fixed' ? 10 : kind === 'expo' ? Math.round(exp(c)) : 1 + Math.floor(rng() * exp(c));
    for (let t = 0; t < T; t++) {
      const arr = cl.filter((c) => !c.done && c.next === t);
      for (let i = arr.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); const x = arr[i]; arr[i] = arr[j]; arr[j] = x; }
      const cap = arr.length > 2 * CAP ? Math.max(1, CAP - Math.floor((arr.length - 2 * CAP) / 4)) : CAP;
      const served = t < DOWN ? 0 : Math.min(cap, arr.length);
      arr.forEach((c, i) => { attempts++; if (i < served) { c.done = true; } else { rejected++; c.att++; c.next = t + delay(c); } });
      peak = Math.max(peak, arr.length);
      ticks.push({ served, rej: arr.length - served });
      if (doneTick < 0 && cl.every((c) => c.done)) doneTick = t;
    }
    return { ticks, attempts, rejected, peak, doneTick, left: cl.filter((c) => !c.done).length };
  }
  extraVals() {
    const st = this.state, brk = st.brk, key = st.useKey;
    // ---- idempotency ledger (provider side) ----
    const atts = st.attBrk === brk && st.attKey === key ? st.att : [];
    const K = key ? 'order-o1' : '(none)';
    let charges = [1, 0, 0, 1, 1][brk];
    const G = '#E2F4E7', R = '#FDECEA', N = '#F1EEE8';
    const ledger = [{ req: '#1', key: K, bg: charges ? G : N,
      result: brk === 1 ? 'never arrived: nothing recorded' : brk === 2 ? 'arrived incomplete: discarded' : 'card charged · ch_1 · response stored' + (key ? ' under the key' : '') }];
    const E = [];
    if (brk === 1) E.push({ f: 0, t: 1, label: 'connect', lost: true, color: 'grey' }, { f: 0, kind: 'note', label: 'NotSent', color: 'blue' });
    else if (brk === 2) E.push({ f: 0, t: 2, label: 'POST /charges', lost: true }, { f: 0, kind: 'note', label: 'MaybeSent', color: 'amber' });
    else {
      E.push({ f: 0, t: 2, label: 'POST /charges' + (key ? ' + key' : '') }, { f: 2, kind: 'note', label: 'charges the card', color: 'pink' });
      if (brk === 0) E.push({ f: 2, t: 0, label: '200 OK', color: 'green', dash: true });
      else E.push({ f: 2, t: 0, label: 'reply', lost: true, color: 'grey' }, { f: 0, kind: 'note', label: 'MaybeSent', color: 'amber' });
    }
    atts.forEach((a, i) => {
      E.push({ f: 0, t: 2, label: 'retry' + (key ? ' + same key' : '') });
      if (key && charges > 0) { ledger.push({ req: '#' + (i + 2), key: K, bg: G, result: 'key seen before → stored response replayed, no new charge' }); E.push({ f: 2, kind: 'note', label: 'replays stored result', color: 'green' }); }
      else { charges++; ledger.push({ req: '#' + (i + 2), key: K, bg: charges > 1 ? R : G, result: charges > 1 ? 'NEW charge · ch_' + charges : 'card charged · ch_1' }); E.push({ f: 2, kind: 'note', label: charges > 1 ? 'charges AGAIN' : 'charges the card', color: charges > 1 ? 'red' : 'pink' }); }
      E.push({ f: 2, t: 0, label: '200 OK', color: 'green', dash: true });
    });
    const retryX = () => {
      const v = this.renderVals(); v.retry();
      const s = this.state, same = s.attBrk === s.brk && s.attKey === s.useKey;
      const patch = { att: (same ? s.att : []).concat([1]), attBrk: s.brk, attKey: s.useKey };
      if (s.brk === 0 && s.useKey) patch.retryResult = 'Same key: the provider recognises it and replays the stored answer. Still charged exactly once.';
      this.setState(patch);
    };
    // ---- thundering herd ----
    const H = [['imm', 'Retry immediately'], ['fixed', 'Wait 1 s'], ['expo', 'Exponential backoff'], ['jitter', 'Backoff + jitter']];
    const sim = this.herdSim(st.herd), sc = 170 / 80, upto = Math.min(st.herdT, 75);
    const herdBars = sim.ticks.map((t, i) => {
      const hs = i < upto ? t.served * sc : 0, hr = i < upto ? t.rej * sc : 0;
      return { x: 41 + i * 10, w: 8, hs, ys: 180 - hs, hr, yr: 180 - hs - hr };
    });
    const NOTE = {
      imm: 'Immediate retries: the whole crowd hits the service every 100 ms. Overloaded, it serves even fewer than usual, so thousands of attempts are wasted and recovery drags on.',
      fixed: 'A fixed one-second wait just moves the crowd: everyone comes back at the same moment, in waves.',
      expo: 'Exponential backoff spaces the waves out, but clients that failed together stay in lockstep: still waves, now further apart.',
      jitter: 'Backoff plus random jitter breaks the lockstep. Retries spread out under the capacity line and far fewer are turned away.'
    };
    return {
      ledger, retryX,
      chargedText: 'Customer charged ' + charges + (charges === 1 ? ' time' : ' times'),
      chargedBg: charges > 1 ? R : charges === 1 ? G : N, chargedFg: charges > 1 ? '#7A1A12' : charges === 1 ? '#0E4D25' : '#17162B',
      happenChart: GD.msc({ id: 'h4', lanes: ['your app', 'network', 'payment provider'], events: E.slice(-10), laneGap: 210, row: 34, aria: 'Sequence chart of the charge request, the provider effect and the reply' }),
      herdOpts: H.map((h) => ({ label: h[1], cls: st.herd === h[0] ? 'on' : '', pick: () => { this.setState({ herd: h[0] }); this.herdStart(); } })),
      herdBars, herdCapY: 180 - 6 * sc, herdOutW: 100, herdNowX: 40 + upto * 10,
      herdAttempts: sim.attempts, herdPeak: sim.peak, herdRejected: sim.rejected,
      herdDone: sim.doneTick >= 0 ? ((sim.doneTick + 1) / 10).toFixed(1) + ' s' : 'not in 7.5 s (' + sim.left + ' still waiting)',
      herdNote: NOTE[st.herd], herdReplay: () => this.herdStart(),
      herdAria: 'Bar chart of requests per 100 milliseconds after an outage, using the ' + st.herd + ' retry schedule'
    };
  }
  tourDefs() {
    const herd = (k) => ($) => { const o = $().herdOpts; o[['imm', 'fixed', 'expo', 'jitter'].indexOf(k)].pick(); };
    return {
      sorter: { reset: ($) => $().resetSort(), steps: [
        { t: 'Every README has a sentence that starts "Your application owns…". Let’s sort a few jobs together.' },
        { t: 'Pooling and reusing HTTP connections: a mechanism, so the library owns it (HTTP Gun).', a: ($) => $().sortItems[0].pickLib() },
        { t: 'Deciding whether to retry a failed payment: a decision, so your app owns it. HTTP Gun never retries on its own.', a: ($) => $().sortItems[1].pickApp() },
        { t: 'Keeping the conversation history with a model: tempting to say "library"… but LLM Wire is a wire. The history is yours.', a: ($) => $().sortItems[2].pickLib() },
        { t: 'The pattern: libraries own mechanisms, your app owns decisions and lifetimes. Sort the rest yourself.', a: ($) => $().resetSort() }
      ] },
      happen: { reset: () => this.setState({ brk: 2, revealed: false, useKey: false, att: [], attBrk: -1, retryResult: 'Choose a moment, then try a retry.' }), steps: [
        { t: 'We charge a card, and the network breaks at some point. The question: what can your code actually prove?' },
        { t: 'Break it while connecting. Not one byte left your machine: the evidence is NotSent, and a retry is completely safe.', a: ($) => $().breakOpts[1].pick() },
        { t: 'Break it after the request arrived, while the provider works. Your code sees MaybeSent. Peek behind the curtain: the card was charged.', a: ($) => { $().breakOpts[3].pick(); $().reveal(); } },
        { t: 'Retry without an idempotency key. The provider sees a brand-new request: the ledger shows a second charge.', a: ($) => $().retryX() },
        { t: 'Now turn the key on and retry. The provider has seen this key, replays the stored answer, and charges nothing new.', a: ($) => { if (!this.state.useKey) $().toggleKey(); $().retryX(); } },
        { t: 'Losing the reply looks exactly the same to your code. That’s why MaybeSent exists. Break the network yourself now.', a: ($) => $().breakOpts[4].pick() }
      ] },
      herd: { reset: () => { this.setState({ herd: 'imm' }); this.herdStart(); }, steps: [
        { t: '80 clients hit a service that is down for one second. What happens next depends only on their retry schedule.' },
        { t: 'Retry immediately: the crowd hammers the service every 100 ms. Look at all that red.', a: herd('imm'), ms: 5200 },
        { t: 'Exponential backoff: fewer attempts, but clients that failed together retry together. Waves.', a: herd('expo'), ms: 5200 },
        { t: 'Backoff with random jitter: the waves dissolve and retries fit under the capacity line.', a: herd('jitter'), ms: 5200 },
        { t: 'Your retry policy is yours to write, so add jitter. Compare all four yourself.' }
      ] },
      defs: { reset: () => this.setState({ def: 0 }), steps: [
        { t: 'A recurring move: write one typed definition and let the library derive every use from it.' },
        { t: 'A JSON Blueprint codec gives you an encoder, a strict decoder and a JSON Schema.', a: ($) => $().defs[0].pick() },
        { t: 'A Sinal event is shared by producers, typed observers and plain Erlang handlers.', a: ($) => $().defs[1].pick() },
        { t: 'A Relay tool is declared, handled and called from the same definition.', a: ($) => $().defs[2].pick() },
        { t: 'A Decisions point ties output, policy facts, the human card and the gated tool together.', a: ($) => $().defs[4].pick() },
        { t: 'Producer and consumer can’t drift apart: they share the same value. Explore the rest.' }
      ] },
      bounds: { reset: () => this.setState({ firstS: 20, gapS: 10, totalS: 120 }), steps: [
        { t: 'LLM Wire’s three default timeouts for a model call. A healthy call stays inside all of them.' },
        { t: 'The provider takes 250 s to send anything: the 180 s first-progress timeout trips.', a: () => this.setState({ firstS: 250, gapS: 10, totalS: 300 }) },
        { t: 'It starts quickly but then goes quiet for 90 s mid-answer: the 60 s idle-gap timeout trips.', a: () => this.setState({ firstS: 20, gapS: 90, totalS: 300 }) },
        { t: 'Every chunk arrives in time, but the whole call runs 12 minutes: the 600 s whole-call limit trips.', a: () => this.setState({ firstS: 20, gapS: 10, totalS: 720 }) },
        { t: 'Every wait has an end, and a typed failure names which one. Drag the sliders yourself.' }
      ] }
    };
  }
