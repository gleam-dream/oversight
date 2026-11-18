  extraState() { return { ls: this.lease0(), sx: { r1: 5, r2: 8, r3: 6, r4: 4 } }; }
  lease0() {
    this.lrng = GD.rng(3);
    const rows = []; for (let i = 1; i <= 14; i++) rows.push({ id: i, st: 'available', owner: null, work: 0, lease: 0, att: 0, wait: 0 });
    return { rows, ws: [{ alive: true, job: null }, { alive: true, job: null }, { alive: true, job: null }], mode: 'hold', t: 0, beat: false, renewals: 0, done: 0, unc: 0, replays: 0, nextId: 15, log: ['Three workers start. Fourteen jobs are waiting in PostgreSQL.'] };
  }
  extraMount() { clearInterval(this.ltimer); if (GD.motion()) this.ltimer = setInterval(() => this.leaseTick(1), 220); }
  extraUnmount() { clearInterval(this.ltimer); }
  leaseTick(n) {
    const LEASE = 15;
    const L = JSON.parse(JSON.stringify(this.state.ls));
    const say = (m) => { L.log = [m].concat(L.log).slice(0, 8); };
    for (let k = 0; k < n; k++) {
      L.t++; L.beat = L.t % 5 === 0;
      if (L.beat) L.rows.forEach((r) => { if (r.st === 'running' && L.ws[r.owner].alive) { r.lease = LEASE; L.renewals++; } });
      L.ws.forEach((w, wi) => {
        if (!w.alive || w.job != null) return;
        let skipped = 0, pick = null;
        for (const r of L.rows) { if (r.st === 'available') { pick = r; break; } if (r.st === 'running') skipped++; }
        if (!pick) return;
        pick.st = 'running'; pick.owner = wi; pick.lease = LEASE; pick.work = 6 + Math.floor(this.lrng() * 9); pick.work0 = pick.work; pick.att++; w.job = pick.id;
        if (skipped) say('W' + (wi + 1) + ' claimed job ' + pick.id + ', skipping ' + skipped + ' row' + (skipped > 1 ? 's' : '') + ' locked by other workers');
      });
      L.rows.forEach((r) => {
        if (r.st === 'retry') { r.wait--; if (r.wait <= 0) { r.st = 'available'; } return; }
        if (r.st !== 'running') return;
        const w = L.ws[r.owner];
        if (w.alive) {
          r.work--;
          if (r.work <= 0) {
            w.job = null;
            if (this.lrng() < 0.08) { r.st = 'retry'; r.wait = 10; r.owner = null; say('job ' + r.id + ': handler returned an error → retry with backoff'); }
            else { r.st = 'done'; r.owner = null; L.done++; }
          }
        } else {
          r.lease--;
          if (r.lease <= 0) {
            const wi = r.owner; L.ws[wi].job = null; r.owner = null;
            if (L.mode === 'hold') { r.st = 'uncertain'; L.unc++; say('job ' + r.id + ': lease expired with no result → held as Uncertain (did the email go out?)'); }
            else { r.st = 'available'; L.replays++; say('job ' + r.id + ': lease expired → replayed, because you declared it safe to repeat'); }
          }
        }
      });
    }
    this.setState({ ls: L });
  }
  sxRuns() {
    const rng = GD.rng(11), x = this.state.sx, runs = [];
    for (let i = 0; i < 200; i++) {
      const u = [rng(), rng(), rng(), rng(), rng()].map((v) => v * 100);
      let out, so = {};
      if (u[0] < x.r1) { out = 'early'; so = { reserve: 'fail' }; }
      else if (u[1] < x.r2) { out = 'comp'; so = { charge: 'declined' }; }
      else {
        let ok = true;
        if (u[2] < x.r3) { if (u[4] < 60) so.charge = 'maybe-ok'; else { out = 'held'; so.charge = 'maybe-hold'; ok = false; } }
        if (ok) { if (u[3] < x.r4) { out = 'comp'; so.ship = 'fail'; } else out = 'done'; }
      }
      runs.push({ out, so, retried: !!so.charge && so.charge.indexOf('maybe') === 0 });
    }
    return runs;
  }
  extraVals() {
    const L = this.state.ls, LEASE = 15;
    const TONE = { available: ['#FFFFFF', '#17162B', '#E4E0D8'], running: ['#E0E9FD', '#163A8A', '#B8CBF7'], done: ['#E2F4E7', '#0E4D25', '#B9E2C4'], uncertain: ['#FFF1C2', '#5C4300', '#E0B000'], retry: ['#FDF0DC', '#6B3404', '#F3D9B1'] };
    const rows = L.rows.map((r) => {
      const dead = r.st === 'running' && !L.ws[r.owner].alive;
      return { id: r.id, owner: r.owner == null ? '' : 'W' + (r.owner + 1), bg: TONE[r.st][0], fg: TONE[r.st][1], border: dead ? '#B42318' : TONE[r.st][2],
        label: r.st === 'running' ? (dead ? 'owner dead · lease draining' : 'running · attempt ' + r.att) : r.st === 'done' ? 'succeeded' : r.st === 'uncertain' ? 'Uncertain: held' : r.st === 'retry' ? 'retry soon' : 'available',
        lease: r.st === 'running' ? Math.round((r.lease / LEASE) * 100) : 0, leaseColor: dead ? '#B42318' : '#1D4ED8' };
    });
    const workers = L.ws.map((w, i) => { const jr = L.rows.find((r) => r.id === w.job && r.st === 'running'); return {
      prog: jr && jr.work0 ? Math.round(((jr.work0 - jr.work) / jr.work0) * 100) : 0,
      name: 'W' + (i + 1), status: !w.alive ? 'dead' : w.job != null ? 'working' : 'idle',
      sbg: !w.alive ? '#FDECEA' : '#E2F4E7', sfg: !w.alive ? '#7A1A12' : '#0E4D25',
      bg: w.alive ? '#FFFFFF' : '#FBF3F2', border: w.alive ? '#E4E0D8' : '#E9B8B2',
      doing: !w.alive ? (w.job != null ? 'Crashed holding job ' + w.job + '. Nobody renews that lease now.' : 'Crashed.') : w.job != null ? 'Running job ' + w.job : 'Waiting for work',
      btn: w.alive ? 'Kill W' + (i + 1) : 'Restart W' + (i + 1), btnCls: w.alive ? 'btn sm warn' : 'btn sm',
      toggle: () => { const N = JSON.parse(JSON.stringify(this.state.ls)); N.ws[i].alive = !N.ws[i].alive; if (N.ws[i].alive) { N.ws[i].job = null; } N.log = [(N.ws[i].alive ? 'W' + (i + 1) + ' restarted, empty-handed.' : 'W' + (i + 1) + ' died mid-job.')].concat(N.log).slice(0, 8); this.setState({ ls: N }); }
    }; });
    // saga x200
    const x = this.state.sx, runs = this.sxRuns();
    const OC = { done: ['#15803D', 'Completed', 'every step succeeded'], comp: ['#B45309', 'Compensated', 'a later step failed; completed steps undone, newest first'], early: ['#8A8698', 'Stopped early', 'out of stock at the first step: nothing to undo'], held: ['#E0B000', 'Held', 'the charge stayed unknown: held for your app to reconcile'] };
    const squares = runs.map((r, i) => ({ bg: OC[r.out][0], title: 'Checkout ' + (i + 1) + ': ' + OC[r.out][1],
      pick: () => {
        clearInterval(this.anim);
        this.setState({ so: Object.assign({ reserve: 'ok', fraud: 'ok', charge: 'ok', ship: 'ok' }, r.so), crash: false, idx: -1 });
        this.__vals().run();
        const el = document.getElementById('saga'); if (el) el.scrollIntoView({ behavior: GD.motion() ? 'smooth' : 'auto', block: 'start' });
      } }));
    const mix = ['done', 'comp', 'early', 'held'].map((k) => { const n = runs.filter((r) => r.out === k).length; return { n, pct: n / 2, bg: OC[k][0], label: OC[k][1], what: OC[k][2] }; });
    const retried = runs.filter((r) => r.retried).length;
    const rate = (k, label) => ({ label, v: x[k], set: (e) => this.setState({ sx: Object.assign({}, this.state.sx, { [k]: Number(e && e.target ? e.target.value : e) }) }) });
    return {
      rows, workers, beatCls: GD.motion() ? 'pulse' : '', renewals: L.renewals, leaseDone: L.done, leaseUnc: L.unc, leaseReplays: L.replays, leaseLog: L.log,
      leaseModes: [['hold', 'hold as Uncertain (default)'], ['replay', 'replay it']].map((m) => ({ label: m[1], cls: L.mode === m[0] ? 'on' : '', pick: () => this.setState({ ls: Object.assign({}, this.state.ls, { mode: m[0] }) }) })),
      leaseAdd: () => { const N = JSON.parse(JSON.stringify(this.state.ls)); for (let i = 0; i < 6; i++) N.rows.push({ id: N.nextId++, st: 'available', owner: null, work: 0, lease: 0, att: 0, wait: 0 }); N.rows = N.rows.slice(-21); this.setState({ ls: N }); },
      leaseReset: () => this.setState({ ls: this.lease0() }), leaseStep: () => this.leaseTick(5), noMotion: !GD.motion(),
      rates: [rate('r1', 'Out of stock'), rate('r2', 'Card declined'), rate('r3', 'Charge result unknown'), rate('r4', 'Shipping fails')],
      squares, mix,
      sxNote: retried + ' of these runs lost the answer to a charge and retried it, always with the same idempotency key, so no customer paid twice. The held ones wait for a human or a reconciliation job, not a guess.'
    };
  }
  tourDefs() {
    const act = (label) => ($) => { const a = $().actions.find((x) => x.label.indexOf(label) === 0); if (a) a.go(); };
    const pickSo = ($, ci, oi) => $().choices[ci].opts[oi].pick();
    const quick = (n) => () => { if (!GD.motion()) this.leaseTick(n); };
    return {
      grind: { reset: () => this.setState(this.job0()), steps: [
        { t: 'One job, mailer.send, allowed 3 attempts. Every change you see is a row update in PostgreSQL.' },
        { t: 'Submit it. Grind writes the row before anything runs: the job is now Queued.', a: act('Submit now') },
        { t: 'A coordinator for the mailers queue claims it under a lease and starts an attempt process: Executing, attempt 1.', a: act('A coordinator claims it') },
        { t: 'The handler returns an error. Attempts remain, so the job becomes Retryable and waits out a backoff.', a: act('Handler returns an error') },
        { t: 'The backoff passes and it’s claimed again: attempt 2.', a: ($) => { act('Backoff passes')($); act('A coordinator claims it')($); } },
        { t: 'The node dies mid-attempt. Did the email go out? Grind won’t guess: by default the job is held as Uncertain.', a: act('The node dies mid-attempt') },
        { t: 'An operator checks the mail provider and records an audited resolution: it was sent. Now drive a job yourself.', a: act('Audit: the email was sent') }
      ] },
      lease: { reset: () => this.setState({ ls: this.lease0() }), steps: [
        { t: 'Three workers claim rows from the same table. Each claim skips rows other workers have locked, so no job is ever run twice at once.', a: quick(10) },
        { t: 'Blue bars are leases. The pink heart is the renewer: every second, on its own connection, it tops up the leases of live workers.', a: quick(10), ms: 4500 },
        { t: 'Kill W2 in the middle of a job. Nobody renews its lease now: watch its bar drain in red.', a: ($) => { if (this.state.ls.ws[1].alive) $().workers[1].toggle(); quick(8)(); }, ms: 4500 },
        { t: 'The lease expires with no result. By default Grind holds the job as Uncertain instead of guessing whether the email went out.', a: quick(12), ms: 4500 },
        { t: 'Switch to "replay it", for handlers that are safe to repeat, and kill W3. Its job goes back to the queue for another worker.', a: ($) => { $().leaseModes[1].pick(); if (this.state.ls.ws[2].alive) $().workers[2].toggle(); quick(20)(); }, ms: 6000 },
        { t: 'The row is the truth, the process is just borrowed time. Kill and restart workers yourself.' }
      ] },
      tx: { reset: ($) => $().txOpts[0].pick(), steps: [
        { t: 'A new order must send a confirmation email: an order row and a job row that should exist together or not at all.' },
        { t: 'Submit the job inside the order’s transaction and commit: both rows exist.', a: ($) => $().txOpts[0].pick() },
        { t: 'If the order insert fails, the transaction rolls back, and the job vanishes with it. No email about a phantom order.', a: ($) => $().txOpts[1].pick() },
        { t: 'Two separate writes with a crash in between: an order with no email, and nothing records the loss. That’s the bug transactional admission removes.', a: ($) => $().txOpts[2].pick() }
      ] },
      saga: { reset: () => { clearInterval(this.anim); this.setState(this.saga0()); }, steps: [
        { t: 'A checkout saga: reserve stock and run a fraud check in parallel, then charge, then ship.' },
        { t: 'Everything succeeds. The coordinator starts both ready steps at once, then follows the dependencies.', a: ($) => $().run(), ms: 6500 },
        { t: 'Now shipping fails after the charge. Saga undoes what it knows succeeded, newest first: refund, then release the stock.', a: ($) => { pickSo($, 3, 1); $().run(); }, ms: 8000 },
        { t: 'The charge result stays unknown even after retries with the same key. Nothing is undone: the run is held for reconciliation.', a: ($) => { pickSo($, 3, 0); pickSo($, 2, 3); $().run(); }, ms: 8000 },
        { t: 'Crash the node after charging, in a local run: the run dies with its caller, mid-flight, with no record.', a: ($) => { pickSo($, 2, 0); if (!this.state.crash) $().toggleCrash(); if (this.state.durable) $().toggleDur(); $().run(); }, ms: 6500 },
        { t: 'Same crash in durable mode: the checkpoint survives, the run resumes, and the charge is not repeated.', a: ($) => { if (!this.state.durable) $().toggleDur(); $().run(); }, ms: 8000 },
        { t: 'Mix the failures yourself, then scroll down to see two hundred runs at once.' }
      ] },
      sagax: { reset: () => this.setState({ sx: { r1: 5, r2: 8, r3: 6, r4: 4 } }), steps: [
        { t: 'Two hundred checkouts with realistic failure rates. Most complete; a few compensate; a couple stop at the first step.' },
        { t: 'A flaky payment provider: unknown results jump to 30%. Yellow appears: runs Saga refuses to guess about.', a: () => this.setState({ sx: Object.assign({}, this.state.sx, { r3: 30 }) }) },
        { t: 'A bad week for the carrier too: shipping fails 20% of the time, and amber compensations spread.', a: () => this.setState({ sx: Object.assign({}, this.state.sx, { r4: 20 }) }) },
        { t: 'However bad it gets, nobody is charged twice. Now move down the ladder: click any square to replay that exact checkout above.' }
      ] }
    };
  }
