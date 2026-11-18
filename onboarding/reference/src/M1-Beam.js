class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = this.fresh();
  }
  fresh() {
    return {
      procs: ['web', 'cart', 'payment', 'mailer', 'cache'].map((name, i) => ({ id: i, name, alive: true, mail: [], handled: 0 })),
      from: 0, to: 1, linked: false, msgN: 0, nextId: 5,
      log: ['Five processes started. Each one has its own memory and an empty mailbox.'], ev: [],
      mode: 'pre', greedy: false, answers: {}
    };
  }
  msgName() { return ['add_item', 'get_total', 'charge', 'send_receipt', 'ping', 'refresh'][this.state.msgN % 6]; }
  say(s, extra, evs) { const log = [s].concat(this.state.log).slice(0, 12); const ev = (this.state.ev || []).concat(evs || []).slice(-10); this.setState(Object.assign({ log, ev }, extra || {})); }
  isLinkedPair(id) { return this.state.linked && (id === 1 || id === 2); }
  renderVals() {
    const st = this.state;
    const P = st.procs;
    const name = (id) => (P.find((p) => p.id === id) || {}).name;
    const upd = (id, f) => P.map((p) => (p.id === id ? f(Object.assign({}, p)) : p));
    const send = () => {
      const from = P.find((p) => p.id === st.from), to = P.find((p) => p.id === st.to);
      const m = this.msgName();
      if (!from || !to) return;
      if (!from.alive) return this.say(from.name + ' is not running, so it cannot send anything.');
      if (from.id === to.id) return this.say(from.name + ' sent "' + m + '" to itself. Allowed, and sometimes useful as a timer.', { procs: upd(to.id, (p) => { p.mail = p.mail.concat([m]); return p; }), msgN: st.msgN + 1 }, [{ f: from.id, t: to.id, label: m }]);
      if (!to.alive) return this.say(from.name + ' sent "' + m + '" to ' + to.name + ', which is dead. The send still "succeeds": the message is silently dropped. Use a monitor or a timeout to notice.', { msgN: st.msgN + 1 }, [{ f: from.id, t: to.id, label: m + ' (dropped)', lost: true, color: 'grey' }]);
      this.say(from.name + ' copied "' + m + '" into ' + to.name + '’s mailbox and moved on without waiting.', { procs: upd(to.id, (p) => { p.mail = p.mail.concat([m]); return p; }), msgN: st.msgN + 1 }, [{ f: from.id, t: to.id, label: m }]);
    };
    const receive = (id) => () => {
      const p = P.find((x) => x.id === id);
      if (!p || !p.mail.length) return;
      this.say(p.name + ' took "' + p.mail[0] + '" from its mailbox and handled it. Only ' + p.name + ' can touch its own state.', { procs: upd(id, (x) => { x.mail = x.mail.slice(1); x.handled += 1; return x; }) }, [{ f: id, kind: 'note', label: 'handles ' + p.mail[0], color: 'blue' }]);
    };
    const crash = (id) => () => {
      const p = P.find((x) => x.id === id);
      let procs = upd(id, (x) => { x.alive = false; x.mail = []; return x; });
      let msg = p.name + ' crashed. Its memory and ' + p.mail.length + ' queued message(s) are gone. ';
      const evs = [{ f: id, kind: 'crash', label: 'crashes' }];
      if (this.isLinkedPair(id)) {
        const other = id === 1 ? 2 : 1;
        const o = P.find((x) => x.id === other);
        if (o && o.alive) { procs = procs.map((x) => (x.id === other ? Object.assign({}, x, { alive: false, mail: [] }) : x)); msg += o.name + ' was linked, received an exit signal and died too. '; evs.push({ f: id, t: other, label: 'EXIT signal', color: 'red', dash: true }, { f: other, kind: 'crash', label: 'dies too' }); }
      }
      const survivors = procs.filter((x) => x.alive).map((x) => x.name);
      msg += survivors.length ? survivors.join(', ') + ' kept running untouched.' : 'Nothing is left running.';
      this.say(msg, { procs }, evs);
    };
    const restart = (id) => () => {
      this.say(name(id) + ' started again, fresh: empty mailbox, initial state. In module 2 a supervisor does this for you.', { procs: upd(id, (x) => { x.alive = true; x.handled = 0; return x; }) }, [{ f: id, kind: 'note', label: 'started again', color: 'green' }]);
    };
    const spawn = () => {
      if (P.length >= 10) return this.say('That’s enough for this demo. A real node would happily run a million more.');
      const id = st.nextId;
      this.say('Started worker-' + id + ' in microseconds, with a few KB of memory.', { procs: P.concat([{ id, name: 'worker-' + id, alive: true, mail: [], handled: 0 }]), nextId: id + 1 });
    };
    const procs = P.map((p) => {
      const linked = this.isLinkedPair(p.id);
      return Object.assign({}, p, {
        dead: !p.alive, empty: !p.mail.length, count: p.mail.length,
        status: p.alive ? 'running' : 'crashed',
        sbg: p.alive ? '#E2F4E7' : '#FDECEA', sfg: p.alive ? '#0E4D25' : '#7A1A12',
        bg: p.alive ? '#FFFFFF' : '#FBF3F2', border: linked ? '#B0186E' : (p.alive ? '#E4E0D8' : '#E9B8B2'),
        linkNote: linked ? (p.id === 1 ? 'linked ⇄ payment' : 'linked ⇄ cart') : (p.alive ? 'pid #' + (100 + p.id) : 'no longer exists'),
        receive: receive(p.id), crash: crash(p.id), restart: restart(p.id)
      });
    });
    const fromOpts = P.slice(0, 5).map((p) => ({ name: p.name, cls: st.from === p.id ? 'on' : '', pick: () => this.setState({ from: p.id }) }));
    const toOpts = P.slice(0, 5).map((p) => ({ name: p.name, cls: st.to === p.id ? 'on' : '', pick: () => this.setState({ to: p.id }) }));
    const toggleLink = () => this.say(st.linked ? 'Unlinked cart and payment. Their fates are separate again.' : 'Linked cart ⇄ payment. Now crash one of them.', { linked: !st.linked });

    // scheduling simulation
    const names = ['A', 'B', 'C', 'D'].concat(st.greedy ? ['G'] : []);
    const lanes = [[], []];
    let queue = names.slice();
    const hog = [null, null];
    for (let t = 0; t < 16; t++) {
      for (let c = 0; c < 2; c++) {
        let p;
        if (hog[c]) p = hog[c];
        else { p = queue.shift(); queue.push(p); if (st.mode === 'coop' && p === 'G') { hog[c] = 'G'; queue = queue.filter((x) => x !== 'G'); } }
        lanes[c].push(p);
      }
    }
    const last = {}; let maxWait = 0;
    for (let t = 0; t < 16; t++) for (let c = 0; c < 2; c++) {
      const p = lanes[c][t];
      if (p === 'G') continue;
      if (last[p] !== undefined) maxWait = Math.max(maxWait, t - last[p] - 1);
      last[p] = t;
    }
    ['A', 'B', 'C', 'D'].forEach((p) => { if (last[p] !== undefined) maxWait = Math.max(maxWait, 15 - last[p]); else maxWait = 16; });
    const col = { A: ['#DCD9FF', '#241F6B'], B: ['#C9E8FF', '#0B3A66'], C: ['#DDF3F0', '#0B4A45'], D: ['#FDF0DC', '#6B3404'], G: ['#B42318', '#FFFFFF'] };
    const laneVals = lanes.map((l, i) => ({ name: 'core ' + (i + 1), slots: l.map((p) => ({ p, bg: col[p][0], fg: col[p][1] })) }));
    const schedNote = !st.greedy ? 'Four well-behaved processes share two cores. Everyone gets a turn every couple of slices.'
      : st.mode === 'coop' ? 'Cooperative scheduling: the greedy process grabbed core 1 and never gave it back. Everyone else now squeezes onto one core, and if a second greedy process appeared the system would freeze. This is how a single bad loop takes down services on many runtimes.'
      : 'Preemptive scheduling, the BEAM way: the greedy process is cut off after its budget like everyone else. It gets its fair share and nothing more, so the system stays responsive.';
    const modes = [{ id: 'coop', label: 'Cooperative (most runtimes)' }, { id: 'pre', label: 'Preemptive (the BEAM)' }]
      .map((m) => ({ label: m.label, cls: st.mode === m.id ? 'on' : '', pick: () => this.setState({ mode: m.id }) }));

    const qs = [
      { q: 'The process handling a payment crashes halfway through. What happens to the separate process holding the shopping cart?',
        o: ['It crashes too, because they share memory', 'Nothing, unless the two were linked on purpose', 'The whole virtual machine restarts'], c: 1,
        e: 'Processes share no memory. Failure only spreads through links you create on purpose, which is exactly how supervisors notice crashes.' },
      { q: 'You send a message to a process that already died. What happens?',
        o: ['The send raises an error', 'The message waits until the process comes back', 'The message is dropped silently; a monitor or a timeout is how you notice'], c: 2,
        e: 'Sending is fire-and-forget and never fails. That’s why BEAM code uses monitors, timeouts and replies, and why gleam-dream libraries put explicit deadlines on every call.' },
      { q: 'Why can’t one runaway loop freeze a BEAM application?',
        o: ['The BEAM kills any loop after 5 seconds', 'Schedulers preempt every process after a small work budget', 'Each process runs on its own OS thread'], c: 1,
        e: 'Preemptive scheduling gives every process a slice and then moves on. The greedy process keeps running, but only its fair share.' }
    ];
    return Object.assign({
      procs, fromOpts, toOpts, send, spawn, nextMsg: this.msgName(), log: st.log,
      reset: () => this.setState(this.fresh()),
      toggleLink, linkLabel: st.linked ? 'Unlink cart ⇄ payment' : 'Link cart ⇄ payment',
      linkBtnCls: st.linked ? 'btn on' : 'btn',
      procCount: P.filter((p) => p.alive).length,
      modes, lanes: laneVals, maxWait, schedNote,
      greedyCls: st.greedy ? 'btn warn' : 'btn',
      greedyLabel: st.greedy ? 'Remove the greedy process' : 'Add a greedy process (G)',
      toggleGreedy: () => this.setState({ greedy: !st.greedy })
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
