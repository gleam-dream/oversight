  extraState() { return { tr: 'ok', tcur: 1 }; }
  extraUnmount() { clearInterval(this.tanim); }
  trace() {
    const E = (f, t, name, by, meaning, fields) => ({ f, t, name, by, meaning, fields: fields || '' });
    const common = [
      E(0, 1, 'grind.job.admitted', 'grind', 'The order row and the job row were written in one transaction. From here on, the work is durable.', 'job reference, committed state'),
      E(1, null, 'grind.job.claimed', 'grind', 'A queue coordinator claimed the job under a database lease and started an attempt process.'),
      E(1, 2, 'saga.run.start', 'saga', 'The job’s handler drives the checkout saga by its stable execution id.'),
      E(2, 4, 'saga.step.start · reserve_inventory', 'saga', 'The first step calls the inventory service (through HTTP Gun, condensed here).'),
      E(4, 2, 'saga.step.stop · reserve_inventory', 'saga', 'Stock is held. The step is checkpointed and enters the undo journal.'),
      E(2, 3, 'saga.step.start · charge_payment', 'saga', 'The charge step starts, with an idempotency key that every attempt reuses. Zooming into HTTP Gun for this one.'),
      E(3, null, 'http_gun.lifecycle · admission_granted', 'http_gun', 'The client pool admitted the request and selected a connection.', 'request id, correlation, client, mode, milestone'),
      E(3, 4, 'http_gun.lifecycle · gun_call_returned', 'http_gun', 'Gun accepted the request. Notice what this does not prove: that the provider received it. That gap is MaybeSent.', 'milestone: GunCallReturned'),
      E(1, null, 'grind.diagnostic.renewal', 'grind', 'Meanwhile, the renewer extended the job’s lease on its own connection.'),
      E(4, 3, 'http_gun.lifecycle · response_headers', 'http_gun', 'The response headers (status 200) passed HTTP Gun’s checks.', 'milestone: ResponseHeaders(200)'),
      E(3, 2, 'http_gun.lifecycle · http_terminated', 'http_gun', 'The exchange settled as Complete: HTTP finished. Whether the body means success is the app’s call.', 'milestone: HttpTerminated(Complete)'),
      E(2, null, 'saga.step.stop · charge_payment', 'saga', 'Payment confirmed and checkpointed.'),
      E(2, 4, 'saga.step.start · book_shipment', 'saga', 'The last step books the carrier.')
    ];
    const ok = [
      E(4, 2, 'saga.step.stop · book_shipment', 'saga', 'Shipment booked.'),
      E(2, 1, 'saga.run.stop', 'saga', 'Every step succeeded; the run reports its terminal outcome.'),
      E(1, 0, 'grind.job.acknowledged', 'grind', 'The attempt’s result is stored in the job row: the durable truth for this order.')
    ];
    const fail = [
      E(4, 2, 'saga.step.stop · book_shipment', 'saga', 'The carrier rejected the booking: the step stops with an error.'),
      E(2, 4, 'saga.step.undo.stop · charge_payment', 'saga', 'Undo, newest first: the charge is refunded.'),
      E(2, 4, 'saga.step.undo.stop · reserve_inventory', 'saga', 'Then the stock hold is released.'),
      E(2, 1, 'saga.run.stop', 'saga', 'The run ends compensated, with every undo result kept as evidence.'),
      E(1, 0, 'grind.job.acknowledged', 'grind', 'The attempt’s result is stored in the job row. The order fails cleanly, with nothing left half-done.')
    ];
    return common.concat(this.state.tr === 'ok' ? ok : fail);
  }
  extraVals() {
    const T = this.trace(), N = T.length, cur = Math.max(1, Math.min(this.state.tcur, N)), e = T[cur - 1];
    const LIBC = { grind: ['#FDF0DC', '#6B3404', 'amber', 'Grind'], saga: ['#FCE7F3', '#5E0B3A', 'pink', 'Saga'], http_gun: ['#E0E9FD', '#163A8A', 'blue', 'HTTP Gun'] };
    const short = (x) => { const p = x.name.split(' · '); if (x.by === 'http_gun') return 'lifecycle: ' + p[1]; return p[1] ? p[0] + ' (' + p[1].split('_')[0] + ')' : p[0]; };
    const events = T.map((x) => ({ f: x.f, t: x.t, kind: x.t == null ? 'note' : undefined, label: short(x), color: LIBC[x.by][2] }));
    const parts = e.name.split(' · ');
    const list = '[' + parts[0].split('.').map((p) => '"' + p + '"').join(', ') + ']' + (parts[1] ? '  ' + parts[1] : '');
    const lanes = ['your app', 'Grind', 'Saga', 'HTTP Gun', 'providers'];
    return {
      trOpts: [['ok', 'Everything succeeds'], ['fail', 'Shipping fails']].map((o) => ({ label: o[1], cls: this.state.tr === o[0] ? 'on' : '', pick: () => { clearInterval(this.tanim); this.setState({ tr: o[0], tcur: 1 }); } })),
      traceChart: GD.msc({ id: 'tr', lanes, events, upto: cur, laneGap: 165, row: 26, numbers: true, active: e.t == null ? e.f : e.t, aria: 'Trace of the durable checkout as telemetry events, event ' + cur + ' of ' + N }),
      trEv: { list, by: LIBC[e.by][3], bg: LIBC[e.by][0], fg: LIBC[e.by][1], meaning: e.meaning, fields: e.fields, hasFields: !!e.fields },
      trCur: cur, trTotal: N, trAtStart: cur <= 1, trAtEnd: cur >= N,
      trBack: () => this.setState({ tcur: Math.max(1, cur - 1) }), trNext: () => this.setState({ tcur: Math.min(N, cur + 1) }),
      trSet: (ev) => this.setState({ tcur: Number(ev && ev.target ? ev.target.value : ev) }),
      trPlay: () => {
        clearInterval(this.tanim);
        if (!GD.motion()) { this.setState({ tcur: N }); return; }
        this.setState({ tcur: 1 });
        this.tanim = setInterval(() => { const n = this.trace().length; if (this.state.tcur >= n) { clearInterval(this.tanim); return; } this.setState({ tcur: this.state.tcur + 1 }); }, 800);
      }
    };
  }
  tourDefs() {
    return {
      systems: { reset: () => { clearInterval(this.anim); this.setState({ sys: 0, cur: 1 }); }, steps: [
        { t: 'Ten real applications from the Oversight repository. Lit chips are the packages each one uses.' },
        { t: 'Checkout: watch which package does what as the steps play. Grind keeps it durable; Saga keeps it ordered and undoable.', a: ($) => { $().systems[0].pick(); $().playAll(); }, ms: 9800 },
        { t: 'Payout desk: an agent proposes, a decision point decides, a saga pays. Fabric never moves money itself.', a: ($) => { $().systems[8].pick(); $().playAll(); }, ms: 7600 },
        { t: 'Pick any system and step through it yourself.' }
      ] },
      builder: { reset: () => this.setState({ need: { durable: true, steps: true } }), steps: [
        { t: 'Tick what a system must do; get the packages, the patterns and the nearest example. This one needs durable, undoable steps: Grind plus Saga, like checkout.' },
        { t: 'A different system: typed answers from an LLM, run in the background. LLM Wire, JSON Blueprint, Grind: the invoice extractor.', a: () => this.setState({ need: { model: true, durable: true } }) },
        { t: 'Add an agent with tools and a human approver: Fabric hands risky calls to a Decisions point.', a: () => this.setState({ need: { model: true, durable: true, agent: true, human: true } }) },
        { t: 'Now design your own.' }
      ] },
      trace: { reset: () => { clearInterval(this.tanim); this.setState({ tr: 'ok', tcur: 1 }); }, steps: [
        { t: 'The durable checkout as a trace. Event 1: Grind admitted the job in the same transaction as the order.' },
        { t: 'Grind claims the job and its handler starts the saga. Every arrow is a real Sinal event name.', a: () => this.setState({ tcur: 3 }) },
        { t: 'Zoom into the charge: HTTP Gun reports milestones. gun_call_returned does not prove the provider got the request: the MaybeSent gap from module 4.', a: () => this.setState({ tcur: 8 }) },
        { t: 'Meanwhile Grind’s renewer keeps the lease alive, then the response settles and the step is checkpointed.', a: () => this.setState({ tcur: 12 }) },
        { t: 'The run completes and Grind stores the outcome in the job row: the durable truth.', a: () => this.setState({ tcur: 16 }) },
        { t: 'Same trace when shipping fails: the undo events run newest first, then the run stops compensated. Scrub through it yourself.', a: () => this.setState({ tr: 'fail', tcur: 18 }) }
      ] }
    };
  }
