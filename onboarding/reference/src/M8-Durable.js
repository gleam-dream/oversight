class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = Object.assign({ answers: {}, tx: 'commit' }, this.job0(), this.saga0());
  }
  job0() { return { js: 'New', attempts: 0, abandon: 'uncertain', jlog: ['Nothing submitted yet.'] }; }
  saga0() { return { so: { reserve: 'ok', fraud: 'ok', charge: 'ok', ship: 'ok' }, crash: false, durable: true, idx: -1 }; }
  componentWillUnmount() { clearInterval(this.anim); }
  sagaEvents() {
    const o = this.state.so, E = [];
    const ev = (set, log, outcome) => E.push({ set, log, outcome });
    ev({ reserve: 'running', fraud: 'running' }, 'Coordinator starts both ready steps at once: they don’t depend on each other.');
    ev({ reserve: o.reserve === 'ok' ? 'done' : 'failed', fraud: o.fraud === 'ok' ? 'done' : 'failed' },
      (o.reserve === 'ok' ? 'Reserve: stock held (hold-o-1).' : 'Reserve: Error(OutOfStock).') + ' ' + (o.fraud === 'ok' ? 'Fraud check: clear.' : 'Fraud check: flagged.'));
    if (o.reserve !== 'ok' || o.fraud !== 'ok') {
      if (o.reserve === 'ok') ev({ reserve: 'undone' }, 'Undo journal: release hold-o-1. The fraud check was read-only, so it has nothing to undo.');
      ev({ charge: 'skipped', ship: 'skipped' }, 'Charge and ship never start: their inputs never arrived.', o.reserve !== 'ok' ? 'Aborted: OutOfStock' : 'Aborted: flagged');
      return E;
    }
    ev({ charge: 'running' }, 'Charge payment with idempotency key checkout:o-1:charge. Every attempt reuses it.');
    if (o.charge === 'declined') {
      ev({ charge: 'failed' }, 'Charge: Error(Declined). A known failure: nothing was taken.');
      ev({ reserve: 'undone', ship: 'skipped' }, 'Undo journal, newest first: release hold-o-1.', 'Aborted: Declined');
      return E;
    }
    if (o.charge === 'maybe-ok' || o.charge === 'maybe-hold') {
      ev({ charge: 'unknown' }, 'Charge: connection lost. MaybeCharged is marked "unknown". Policy: RetryAfter 500 ms with the same key.');
      ev({ charge: 'running' }, 'Attempt 2, same idempotency key.');
      if (o.charge === 'maybe-ok') ev({ charge: 'done' }, 'The provider recognised the key and returned the original result: charged exactly once.');
      else {
        ev({ charge: 'unknown' }, 'Attempt 2: still unknown. Attempt 3: still unknown.');
        ev({ charge: 'held', ship: 'skipped' }, 'Policy answers Hold(MaybeCharged). Nothing is undone: releasing stock for an order that may be paid would be wrong. Your app checks the provider by key and resolves it.', 'Held for reconciliation');
        return E;
      }
    } else ev({ charge: 'done' }, 'Charge: receipt-checkout:o-1:charge.');
    if (this.state.crash) {
      if (this.state.durable) ev({ ship: 'idle' }, 'NODE CRASHED. The checkpoint says reserve, fraud and charge are complete. On restart, Grind redelivers the job driving this saga; it reconnects by execution id and resumes. The charge is not repeated.');
      else { ev({ ship: 'skipped' }, 'NODE CRASHED. A local run lives and dies with its caller: stock is held, the card is charged, nothing ships, and no record says where it stopped.', 'Lost: use durable mode'); return E; }
    }
    ev({ ship: 'running' }, 'Book shipment.');
    if (o.ship === 'ok') ev({ ship: 'done' }, 'Shipment booked. Every step succeeded.', 'Completed');
    else {
      ev({ ship: 'failed' }, 'Ship: the carrier rejected the booking.');
      ev({ charge: 'undone' }, 'Undo journal, newest first: refund the charge (with its own idempotency key).');
      ev({ reserve: 'undone' }, 'Then release hold-o-1.', 'Aborted: compensated');
    }
    return E;
  }
  renderVals() {
    const st = this.state;
    // ---------- Grind ----------
    const NAMES = [['Scheduled', 'waiting for its time'], ['Queued', 'ready to run'], ['Executing', 'claimed, leased'], ['Retryable', 'failed, will retry'], ['Succeeded', 'output stored'], ['BusinessFailed', 'out of attempts'], ['Uncertain', 'effect unknown'], ['Discarded', 'handler gave up'], ['Cancelled', 'stopped by you']];
    const states = NAMES.map((n) => {
      const on = st.js === n[0];
      const terminal = ['Succeeded', 'BusinessFailed', 'Discarded', 'Cancelled'].indexOf(n[0]) >= 0;
      return { name: n[0], tiny: n[1], bg: on ? '#6B3404' : '#FFFFFF', fg: on ? '#FFFFFF' : (terminal ? '#5B5970' : '#17162B'), border: on ? '#6B3404' : '#E4E0D8' };
    });
    const go = (to, msg, extra) => () => {
      const s = this.state;
      this.setState(Object.assign({ js: to, jlog: [s.js === 'New' ? '' : '', msg].filter(Boolean).concat(s.jlog.filter((l) => l !== 'Nothing submitted yet.')).slice(0, 10) }, extra || {}));
    };
    const A = (label, to, msg, extra, warn) => ({ label, go: go(to, msg, extra), cls: 'btn' + (warn ? ' warn' : '') });
    const n = st.attempts;
    const WHY = {
      New: 'Submit the job. Grind writes a row before anything runs.',
      Scheduled: 'The row waits for its time. A snoozed job comes back here too.',
      Queued: 'Ready. A coordinator for the "mailers" queue will claim it when it has local capacity.',
      Executing: 'Claimed under a database lease. An attempt process runs your handler; a separate renewer keeps the lease alive on its own connection.',
      Retryable: 'Failed, with attempts left. It will be queued again after a backoff.',
      Succeeded: 'Done. The typed output is stored in the row, and anyone can await it.',
      BusinessFailed: 'Out of attempts. The last error is stored. Terminal.',
      Uncertain: 'The attempt was abandoned mid-effect. By default Grind doesn\u2019t guess whether the email went out: an operator resolves it with evidence, and the resolution is audited. Replay is opt-in, for handlers where repeating is safe.',
      Discarded: 'The handler decided this job should never run again. Terminal.',
      Cancelled: 'Stopped before it ran. Terminal.'
    };
    let actions = [];
    if (st.js === 'New') actions = [A('Submit now', 'Queued', 'submit → Queued (row inserted)'), A('Submit for 10 minutes from now', 'Scheduled', 'submit at +10m → Scheduled')];
    else if (st.js === 'Scheduled') actions = [A('The time arrives', 'Queued', 'scheduled time reached → Queued'), A('Cancel it', 'Cancelled', 'cancelled → Cancelled', null, true)];
    else if (st.js === 'Queued' || st.js === 'Retryable') actions = st.js === 'Retryable' ? [A('Backoff passes', 'Queued', 'backoff elapsed → Queued')] : [A('A coordinator claims it', 'Executing', 'claimed with a lease → Executing (attempt ' + (n + 1) + ')', { attempts: n + 1 })];
    else if (st.js === 'Executing') actions = [
      A('Handler returns Ok', 'Succeeded', 'attempt ' + n + ': Ok("msg:ada@example.com") → Succeeded'),
      n < 3 ? A('Handler returns an error', 'Retryable', 'attempt ' + n + ': Error(SmtpTimeout) → Retryable') : A('Handler returns an error', 'BusinessFailed', 'attempt ' + n + ': Error(SmtpTimeout), no attempts left → BusinessFailed', null, true),
      A('Handler asks to snooze 5 min', 'Scheduled', 'attempt ' + n + ': snooze 5m → Scheduled'),
      A('Handler discards the job', 'Discarded', 'attempt ' + n + ': discard → Discarded', null, true),
      st.abandon === 'replay'
        ? A('The node dies mid-attempt', 'Queued', 'node lost; lease expired → replayed (you declared replay safe, up to a max) → Queued', null, true)
        : A('The node dies mid-attempt', 'Uncertain', 'node lost; lease expired → held as Uncertain (did the email go out?)', null, true)
    ];
    else if (st.js === 'Uncertain') actions = [A('Audit: the email was sent', 'Succeeded', 'operator resolution (audited): effect happened → Succeeded'), A('Audit: it was not sent', 'Queued', 'operator resolution (audited): effect did not happen → Queued', null)];
    else actions = [A('Start over with a new job', 'New', 'reset', { attempts: 0, jlog: ['Nothing submitted yet.'] })];
    const abandonOpts = [['uncertain', 'hold as Uncertain (default)'], ['replay', 'replay after lease expiry']].map((a) => ({ label: a[1], cls: st.abandon === a[0] ? 'on' : '', pick: () => this.setState({ abandon: a[0] }) }));
    // transactional admission
    const TX = {
      commit: ['Order o-1', 'mailer.send for o-1', 'Both, or…', 'Committed together. The email will be sent for an order that really exists.', '#E2F4E7', '#E2F4E7', '#E2F4E7', 'Consistent: both exist'],
      rollback: ['(nothing)', '(nothing)', '', 'The order insert failed, so the whole transaction rolled back, job included. No email about an order that doesn’t exist.', '#F1EEE8', '#F1EEE8', '#E2F4E7', 'Consistent: neither exists'],
      apart: ['Order o-1', '(nothing)', '', 'Two separate writes, and the node crashed between them. The order is saved, but no email will ever be sent, and nothing records that it was supposed to be.', '#E2F4E7', '#FDECEA', '#FDECEA', 'Inconsistent: a lost job']
    }[st.tx];
    const txOpts = [['commit', 'Same transaction: commits'], ['rollback', 'Same transaction: rolls back'], ['apart', 'Two separate writes + crash']].map((t) => ({ label: t[1], cls: st.tx === t[0] ? 'on' : '', pick: () => this.setState({ tx: t[0] }) }));

    // ---------- Saga ----------
    const E = this.sagaEvents();
    const idx = Math.min(st.idx, E.length - 1);
    const status = { reserve: 'idle', fraud: 'idle', charge: 'idle', ship: 'idle' };
    let outcome = idx < 0 ? 'Not started' : 'Running…';
    const sagaLog = [];
    for (let i = 0; i <= idx; i++) { Object.assign(status, E[i].set); sagaLog.unshift(E[i].log); if (E[i].outcome) outcome = E[i].outcome; }
    const TONE = { idle: ['#FFFFFF', '#5B5970', '#E4E0D8', 'waiting'], running: ['#FFFBF4', '#6B3404', '#B45309', 'running…'], done: ['#E2F4E7', '#0E4D25', '#B9E2C4', 'done'], failed: ['#FDECEA', '#7A1A12', '#B42318', 'failed'], undone: ['#EDEFF3', '#3B4452', '#B8C0CC', 'undone'], unknown: ['#FFF1C2', '#5C4300', '#E0B000', 'unknown!'], held: ['#FFF1C2', '#5C4300', '#E0B000', 'held for reconciliation'], skipped: ['#F6F7F9', '#8A8698', '#E4E0D8', 'skipped'] };
    const node = (id, name) => ({ name, status: TONE[status[id]][3], bg: TONE[status[id]][0], fg: TONE[status[id]][1], border: TONE[status[id]][2] });
    const run = () => {
      clearInterval(this.anim);
      if (!GD.motion()) { this.setState({ idx: this.sagaEvents().length - 1 }); return; }
      this.setState({ idx: 0 });
      this.anim = setInterval(() => {
        const total = this.sagaEvents().length;
        if (this.state.idx >= total - 1) { clearInterval(this.anim); return; }
        this.setState({ idx: this.state.idx + 1 });
      }, 900);
    };
    const CH = [
      ['Reserve stock', 'reserve', [['ok', 'in stock'], ['fail', 'out of stock']]],
      ['Fraud check', 'fraud', [['ok', 'clear'], ['flag', 'flagged']]],
      ['Charge payment', 'charge', [['ok', 'ok'], ['declined', 'declined'], ['maybe-ok', 'unknown, then ok'], ['maybe-hold', 'stays unknown']]],
      ['Book shipment', 'ship', [['ok', 'ok'], ['fail', 'fails']]]
    ];
    const choices = CH.map((c) => ({ label: c[0], opts: c[2].map((o) => ({ label: o[1], cls: st.so[c[1]] === o[0] ? 'on' : '', pick: () => { clearInterval(this.anim); this.setState({ so: Object.assign({}, st.so, { [c[1]]: o[0] }), idx: -1 }); } })) }));
    const good = outcome === 'Completed', bad = outcome.indexOf('Aborted') === 0 || outcome.indexOf('Lost') === 0, held = outcome.indexOf('Held') === 0;

    const qs = [
      { q: 'An order row and its confirmation-email job must both exist, or neither. Which Grind feature gives you that?',
        o: ['Submitting the job inside the caller’s open transaction', 'Unique jobs', 'Snoozing the job until the order is saved'], c: 0,
        e: 'Transactional admission stages the job in your transaction, so it commits or rolls back with your own write. That’s the "outbox" pattern without a separate outbox.' },
      { q: 'Reserve and charge succeeded, then shipping fails. What does Saga do?',
        o: ['Retries shipping forever', 'Undoes completed steps newest first: refund, then release the stock', 'Nothing; the caller has to clean up'], c: 1,
        e: 'Only known successful steps enter the undo journal, and they’re undone in reverse. Each undo is attempted once and its failures are kept as evidence.' },
      { q: 'The charge is still unknown after every retry. What’s Saga’s honest move?',
        o: ['Assume it failed and release the stock', 'Hold the run for reconciliation with authoritative evidence', 'Mark it succeeded to keep the customer happy'], c: 1,
        e: 'Hold keeps the uncertainty visible. Your application checks the provider, by idempotency key, and resolves it. The same pattern as Grind’s Uncertain state.' }
    ];
    return Object.assign({
      states, jobState: st.js === 'New' ? 'Not submitted' : st.js, jobWhy: WHY[st.js], attempts: n, actions, jobLog: st.jlog, abandonOpts,
      txOpts, orderRow: TX[0], jobRow: TX[1], txWhy: TX[3], orderBg: TX[4], jobBg: TX[5], txVerdictBg: TX[6], txVerdict: TX[7],
      choices, run, resetSaga: () => { clearInterval(this.anim); this.setState(this.saga0()); },
      nodesA: [node('reserve', 'Reserve stock'), node('fraud', 'Fraud check')], nodesB: [node('charge', 'Charge payment')], nodesC: [node('ship', 'Book shipment')],
      outcome, outBg: good ? '#E2F4E7' : bad ? '#FDECEA' : held ? '#FFF1C2' : '#F1EEE8', outFg: good ? '#0E4D25' : bad ? '#7A1A12' : held ? '#5C4300' : '#17162B',
      sagaLog: sagaLog.length ? sagaLog : ['Press "Run checkout".'],
      crashLabel: st.crash ? 'Crash after charge: on' : 'Crash the node after charging', crashCls: st.crash ? 'btn warn' : 'btn',
      toggleCrash: () => { clearInterval(this.anim); this.setState({ crash: !st.crash, idx: -1 }); },
      durLabel: st.durable ? 'Durable mode: on (checkpoints)' : 'Durable mode: off (local run)', durCls: st.durable ? 'btn on' : 'btn',
      toggleDur: () => { clearInterval(this.anim); this.setState({ durable: !st.durable, idx: -1 }); }
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
