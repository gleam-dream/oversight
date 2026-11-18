class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { answers: {}, status: 'refunded', rcpt: false, refund: true, variant: 1, disputed: false, fails: {}, erl: [], glm: [] };
  }
  renderVals() {
    const st = this.state;
    // impossible states
    const looseStatus = ['pending', 'paid', 'refunded'].map((s) => ({ label: s, cls: st.status === s ? 'on' : '', pick: () => this.setState({ status: s }) }));
    const want = { pending: [false, false], paid: [true, false], refunded: [true, true] }[st.status];
    const ok = want[0] === st.rcpt && want[1] === st.refund;
    let why;
    if (ok) why = 'This one happens to make sense. Nothing stopped the other eleven.';
    else if (st.status === 'refunded' && !st.rcpt) why = 'Refunded, but never paid? The program accepts it happily. Somewhere later, code that expects a receipt will crash or do something strange.';
    else if (st.status === 'pending' && (st.rcpt || st.refund)) why = 'Pending, yet it already has a receipt or refund. Which field is the truth? Every reader has to guess.';
    else if (st.status === 'paid' && st.refund) why = 'Paid and refunded at once? The data contradicts itself, and every function reading it needs a defensive check.';
    else why = 'A required piece is missing for this status, and nothing in the program noticed.';
    const V = [
      { name: 'Pending', fields: 'no extra data', why: 'Pending carries nothing, so a pending order can’t accidentally hold a receipt.' },
      { name: 'Paid(receipt)', fields: 'must carry a receipt', why: 'You cannot build a Paid order without giving it a receipt. The compiler refuses.' },
      { name: 'Refunded(receipt, refund)', fields: 'must carry both', why: 'A refund always comes with the receipt it reverses. "Refunded but never paid" is not expressible.' }
    ];
    const variants = V.map((v, i) => ({ name: v.name, fields: v.fields, border: st.variant === i ? '#B0186E' : '#E4E0D8', pick: () => this.setState({ variant: i }) }));

    // railway
    const steps = [['Parse request', 'BadRequest'], ['Validate amount', 'InvalidAmount'], ['Reserve stock', 'OutOfStock'], ['Charge card', 'Declined'], ['Send receipt', 'MailNotSent']];
    const firstFail = steps.findIndex((s, i) => st.fails[i]);
    const rail = steps.map((s, i) => {
      let state, bg, border, fg;
      if (firstFail === -1 || i < firstFail) { state = 'Ok → next step'; bg = '#E2F4E7'; border = '#B9E2C4'; fg = '#0E4D25'; }
      else if (i === firstFail) { state = 'Error(' + s[1] + ')'; bg = '#FDECEA'; border = '#B42318'; fg = '#7A1A12'; }
      else { state = 'skipped: never runs'; bg = '#F1EEE8'; border = '#E4E0D8'; fg = '#5B5970'; }
      return { n: i + 1, name: s[0], state, bg, border, fg, btn: st.fails[i] ? 'Make it succeed' : 'Make it fail', btnCls: st.fails[i] ? 'btn sm on' : 'btn sm warn',
        toggle: () => this.setState({ fails: Object.assign({}, st.fails, { [i]: !st.fails[i] }) }) };
    });
    const okPct = firstFail === -1 ? 100 : Math.round((firstFail / steps.length) * 100);
    const errStart = firstFail === -1 ? 100 : Math.round(((firstFail + 0.5) / steps.length) * 100);
    const outcome = firstFail === -1 ? 'Ok(receipt)' : 'Error(' + steps[firstFail][1] + ')';
    const railNote = firstFail === -1 ? 'Everything succeeded: the value flows along the happy track to the end.'
      : 'Step ' + (firstFail + 1) + ' failed, so steps after it never ran. The caller receives ' + outcome + ' as a value and must decide what to do. ' + (firstFail === 3 ? 'Notice the stock is already reserved: undoing earlier steps is a job for Saga, in module 8.' : 'gleam-dream libraries go further: their error types also say whether an effect may already have happened. More in module 4.');

    // typed messages
    const M = [
      { label: 'AddItem(Pen)', ok: true },
      { label: 'GetTotal(reply_to)', ok: true },
      { label: 'ChargeCard(€20)', ok: false, why: 'a PaymentMessage, not a CartMessage' },
      { label: '"hello"', ok: false, why: 'a String, not a CartMessage' }
    ];
    const msgBtns = M.map((m) => ({ label: 'Send ' + m.label, send: () => {
      const erl = st.erl.concat([{ label: m.label, note: m.ok ? 'handled' : 'accepted into the mailbox… then ignored forever or crashes the cart at runtime', bg: m.ok ? '#F1EEE8' : '#FDECEA' }]).slice(-5);
      const glm = st.glm.concat([{ label: m.label, note: m.ok ? 'compiles and is handled' : 'compile error: expected CartMessage, got ' + m.why.replace('a ', '').replace(', not a CartMessage', ''), bg: m.ok ? '#E2F4E7' : '#FFF1C2' }]).slice(-5);
      this.setState({ erl, glm });
    } }));

    const qs = [
      { q: 'An order record with optional fields can represent "refunded but never paid". What is the Gleam way to fix that?',
        o: ['Add a runtime check everywhere the order is read', 'A custom type with one variant per state, each carrying exactly its data', 'Store the status as a carefully documented string'], c: 1,
        e: 'If a state can’t be constructed, no code ever has to defend against it. gleam-dream APIs lean on this constantly, for example a Grind job state or a Fabric run status.' },
      { q: 'You add a Disputed variant to the Order type. What does the compiler do?',
        o: ['Nothing until the code runs', 'Points to every place that matches on Order and doesn’t handle Disputed yet', 'Removes the old variants'], c: 1,
        e: 'Exhaustive matching turns "did we update everything?" into a list of compile errors. That’s why changing a library’s error type is a visible, reviewable event.' },
      { q: 'A gleam-dream function returns Result(Reply, Failure). What does that tell you?',
        o: ['It may throw an exception you should catch', 'It never fails', 'It can fail; the failure is a value you must handle, and the Failure type lists exactly how'], c: 2,
        e: 'Errors are values. Reading a function’s return type tells you its failure modes before you read any docs.' }
    ];
    return Object.assign({
      looseStatus, rcptLabel: st.rcpt ? 'set' : 'empty', refLabel: st.refund ? 'set' : 'empty',
      rcptCls: st.rcpt ? 'btn on' : 'btn', refCls: st.refund ? 'btn on' : 'btn',
      toggleRcpt: () => this.setState({ rcpt: !st.rcpt }), toggleRef: () => this.setState({ refund: !st.refund }),
      looseVerdict: ok ? 'Accepted. Valid by luck.' : 'Accepted. A bug waiting to happen.', looseWhy: why,
      looseBg: ok ? '#F1EEE8' : '#FDECEA', looseFg: ok ? '#17162B' : '#7A1A12',
      variants, typedWhy: V[st.variant].why,
      disputed: st.disputed, dispLabel: st.disputed ? 'Remove Disputed' : 'Add the Disputed state', dispCls: st.disputed ? 'btn on' : 'btn pri',
      toggleDisp: () => this.setState({ disputed: !st.disputed }),
      rail, okPct, errStart, outcome, railNote, outBg: firstFail === -1 ? '#E2F4E7' : '#FDECEA', outFg: firstFail === -1 ? '#0E4D25' : '#7A1A12',
      clearFails: () => this.setState({ fails: {} }),
      msgBtns, erl: st.erl, glm: st.glm, clearMsgs: () => this.setState({ erl: [], glm: [] })
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
