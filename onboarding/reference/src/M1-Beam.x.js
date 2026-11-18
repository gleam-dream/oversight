  extraVals() {
    const P = this.state.procs.slice(0, 6), ids = P.map((p) => p.id);
    const evs = (this.state.ev || []).filter((e) => ids.indexOf(e.f) >= 0 && (e.t == null || ids.indexOf(e.t) >= 0))
      .map((e) => Object.assign({}, e, { f: ids.indexOf(e.f), t: e.t == null ? null : ids.indexOf(e.t) }));
    const chart = GD.msc({ id: 'p1', lanes: P.map((p) => p.name), events: evs.length ? evs : [{ f: 0, kind: 'note', label: 'nothing yet: send a message', color: 'grey' }], laneGap: 150, numbers: true, aria: 'Sequence chart of messages, crashes and restarts between the processes' });
    return { procChart: chart, chartCount: evs.length ? 'last ' + evs.length + ' events' : '' };
  }
  tourDefs() {
    const pick = ($, f, t) => { $().fromOpts[f].pick(); $().toOpts[t].pick(); };
    return {
      proc: { reset: ($) => $().reset(), steps: [
        { t: 'Five processes, each with its own private memory and an empty mailbox. Press Next (or Play) to watch what a single message does.' },
        { t: 'web sends add_item to cart. The message is copied into cart’s mailbox, and web carries on immediately: sending never waits.', a: ($) => { pick($, 0, 1); $().send(); } },
        { t: 'cart takes the message out of its mailbox and handles it. Only cart can ever touch cart’s state.', a: ($) => $().procs[1].receive() },
        { t: 'Now payment crashes. Its memory and mailbox vanish, and every other process keeps running untouched.', a: ($) => $().procs[2].crash() },
        { t: 'web sends to the dead payment process. The send still "succeeds": the message is silently dropped (the lightning bolt in the chart).', a: ($) => { pick($, 0, 2); $().send(); } },
        { t: 'Start payment again, then link it to cart. A link ties two processes’ fates together.', a: ($) => { $().procs[2].restart(); $().toggleLink(); } },
        { t: 'Crash cart: payment receives an EXIT signal and dies too. That is exactly how a supervisor notices failures, in the next module.', a: ($) => $().procs[1].crash() },
        { t: 'The timeline below tells the whole story. Your turn: start processes, send messages, link and crash them.' }
      ] },
      sched: { reset: () => this.setState({ mode: 'pre', greedy: false }), steps: [
        { t: 'Two cores, four well-behaved processes. Each square is one time slice; everyone gets a turn every couple of slices.' },
        { t: 'Add a greedy process G that never stops working, on a cooperative runtime: it grabs core 1 and never gives it back.', a: ($) => { $().modes[0].pick(); if (!this.state.greedy) $().toggleGreedy(); } },
        { t: 'Same greedy process, BEAM style: the scheduler cuts it off after its work budget, like everyone else. The longest wait drops right back down.', a: ($) => $().modes[1].pick() },
        { t: 'That fairness is why one runaway loop can’t freeze a BEAM service. Try the switches yourself.' }
      ] }
    };
  }
