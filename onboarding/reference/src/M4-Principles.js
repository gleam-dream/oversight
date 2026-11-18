class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { answers: {}, habit: 0, sorted: {}, brk: 2, revealed: false, useKey: false, retryResult: 'Choose a moment, then try a retry.', def: 0, firstS: 20, gapS: 10, totalS: 120 };
  }
  renderVals() {
    const st = this.state;
    const H = [
      { title: 'Libraries, not a framework', short: 'Pick only what you need; compose in plain code.', long: 'Each package is independent, with its own API and runtime. There is no shared base, no global registry, no "gleam-dream app". Your application imports a few libraries and connects them with ordinary functions. The Oversight repository shows compositions to read and adapt, not a framework to inherit.', seen: ['every package', 'Oversight example apps'] },
      { title: 'Your app owns decisions', short: 'Libraries own one mechanism. You own policy and lifetimes.', long: 'Libraries do the fiddly mechanical work: pooling, leasing, encoding, refreshing, recording. Your application keeps every decision: who may do what, when to retry, which database pool to use, when things start and stop. Credentials and context stay live in your app instead of being stored by a library.', seen: ['Fabric policy', 'LLM Wire history', 'Hellhound accounts', 'Grind pools'] },
      { title: 'Typed at every boundary', short: 'Define a shape once; derive every use from it.', long: 'JSON goes through codecs. Telemetry events have typed fields. Tools, jobs and decision points are typed definitions shared by both sides. When data crosses into or out of your program, a type checks it at the door.', seen: ['JSON Blueprint codecs', 'Sinal events', 'Relay tools', 'Grind workers'] },
      { title: 'Bounded by default', short: 'Every queue, body and wait has a limit.', long: 'Unbounded things are how healthy services fall over: a queue that grows forever, a response body that never ends, a call that never returns. gleam-dream gives every one of them an explicit limit, a typed failure when it trips, and a way for you to configure it.', seen: ['LLM Wire timeouts', 'HTTP Gun limits', 'Sinal forwarder capacity', 'Fabric budgets'] },
      { title: 'Honest about uncertainty', short: 'NotSent, MaybeSent, Unknown: never a guess.', long: 'When a call to the outside world breaks, packages report what they can prove: definitely not sent, maybe sent, or a real answer. They never retry an effect behind your back. Pair that evidence with idempotency keys and reconciliation, and money moves once.', seen: ['HTTP Gun', 'Correio', 'Saga', 'Grind', 'Fabric', 'Decisions'] },
      { title: 'Records are the truth', short: 'Durable rows decide; telemetry only informs.', long: 'Where something must be remembered, it’s written as a durable record you can query and recover from: job rows, workflow checkpoints, run records, append-only decision entries. Telemetry is best effort and may drop under load.', seen: ['Grind rows', 'Saga checkpoints', 'Fabric store', 'Decisions entries'] },
      { title: 'Pure core, thin shell', short: 'Logic as pure functions; processes just perform effects.', long: 'The interesting logic is a pure function from state and event to new state and effects. A thin OTP process around it does the I/O. That makes the core easy to test, replay and run over different storage, in memory for tests, PostgreSQL in production.', seen: ['Relay reducer', 'Fabric controller', 'Decisions core'] }
    ];
    const habits = H.map((h, i) => ({ n: i + 1, title: h.title, short: h.short,
      bg: st.habit === i ? '#17162B' : '#FFFFFF', fg: st.habit === i ? '#FFFFFF' : '#17162B', border: st.habit === i ? '#17162B' : '#E4E0D8',
      pick: () => this.setState({ habit: i }) }));
    const habit = Object.assign({ n: st.habit + 1 }, H[st.habit]);

    // ownership sorter
    const J = [
      ['Pooling and reusing HTTP connections', 'lib', 'HTTP Gun’s pool process does this, with limits you configure.'],
      ['Deciding whether to retry a failed payment call', 'app', 'HTTP Gun never retries on its own. It gives you evidence; you decide.'],
      ['Keeping the conversation history with a model', 'app', 'LLM Wire is a wire library. The caller owns history, storage and the loop.'],
      ['Encoding a provider request and enforcing size limits', 'lib', 'LLM Wire’s prepare step validates and encodes before any network call.'],
      ['Starting and stopping the PostgreSQL pool', 'app', 'Grind, Saga and Decisions adapters borrow your pool; they never own it.'],
      ['Leasing a job so two nodes never run it at once', 'lib', 'Grind claims work with database leases and renews them on a reserved connection.'],
      ['User accounts and session cookies', 'app', 'Hellhound checks identity and keeps tokens. Accounts and cookies stay yours.'],
      ['Refreshing an expiring token shared by many callers', 'lib', 'Hellhound refreshes near expiry and shares one refresh across concurrent callers.'],
      ['Who may approve a refund over €500', 'app', 'Policy is application data, handed to Fabric or Decisions. The library enforces it.'],
      ['Recording every verdict as an append-only entry', 'lib', 'Decisions keeps the record; an occurrence’s status is a fold over its entries.'],
      ['Exporting metrics to a dashboard', 'app', 'Sinal has no exporter or aggregation. Adapters and your app own those.'],
      ['Email templates and wording', 'app', 'Correio validates, renders MIME and sends. What the email says is yours.']
    ];
    let right = 0, done = 0;
    const sortItems = J.map((j, i) => {
      const g = st.sorted[i];
      const isDone = g !== undefined, ok = g === j[1];
      if (isDone) { done++; if (ok) right++; }
      const pick = (v) => () => this.setState({ sorted: Object.assign({}, st.sorted, { [i]: v }) });
      return { job: j[0], why: j[2], done: isDone, verdict: !isDone ? '' : (ok ? 'Right.' : (j[1] === 'lib' ? 'Library, actually.' : 'Your app, actually.')),
        bg: !isDone ? '#FFFFFF' : (ok ? '#F1FAF3' : '#FEF6F5'), border: !isDone ? '#E4E0D8' : (ok ? '#B9E2C4' : '#E9B8B2'),
        libCls: 'btn sm' + (g === 'lib' ? ' on' : ''), appCls: 'btn sm' + (g === 'app' ? ' on' : ''), pickLib: pick('lib'), pickApp: pick('app') };
    });

    // did it happen?
    const B = [
      { label: 'Never', ev: 'Response: 200 OK', evWhy: 'A real answer came back. A 404 or 500 would be data too: the library reports it, and your code decides what it means.', truth: 'Charged once.', safe: 'Act on the answer. Nothing to reconcile.', charged: 1, kind: 'ok' },
      { label: 'While connecting', ev: 'NotSent', evWhy: 'The connection never opened, so not one byte of the request left your machine. That is provable.', truth: 'Nothing. The provider never heard of you.', safe: 'Retrying is completely safe.', charged: 0, kind: 'not' },
      { label: 'While sending', ev: 'MaybeSent', evWhy: 'Some bytes may have left. The provider might have the full request, part of it, or none.', truth: 'Nothing this time: the request arrived incomplete. But you couldn’t know that.', safe: 'Don’t blindly retry. Retry with the same idempotency key, or ask the provider what it has.', charged: 0, kind: 'maybe' },
      { label: 'While provider works', ev: 'MaybeSent', evWhy: 'The whole request was sent, then the connection died. The provider may be halfway through.', truth: 'Charged once. The card was debited just before the line dropped.', safe: 'Don’t blindly retry. Retry with the same idempotency key, or ask the provider what it has.', charged: 1, kind: 'maybe' },
      { label: 'While reply travels', ev: 'MaybeSent', evWhy: 'The provider finished and replied, but the answer never reached you. To your code this looks identical to the previous case.', truth: 'Charged once.', safe: 'Don’t blindly retry. Retry with the same idempotency key, or ask the provider what it has.', charged: 1, kind: 'maybe' }
    ];
    const b = B[st.brk];
    const breakOpts = B.map((x, i) => ({ label: x.label, cls: st.brk === i ? 'on' : '', pick: () => this.setState({ brk: i, revealed: false, retryResult: 'Connection drops ' + x.label.toLowerCase() + '. Now try a retry.' }) }));
    const stages = [['your app', 'Check destination'], ['network', 'Connect'], ['network', 'Send request'], ['provider', 'Charge the card'], ['network', 'Send reply'], ['your app', 'Read reply']];
    const breakAt = [99, 1, 2, 3, 4][st.brk];
    const journey = stages.map((s, i) => {
      const reached = i < breakAt, broke = i === breakAt;
      return { where: s[0], label: s[1], mark: broke ? 'connection lost' : (reached ? 'done' : 'not reached'),
        bg: broke ? '#FDECEA' : (reached ? '#E2F4E7' : '#F1EEE8'), fg: broke ? '#7A1A12' : (reached ? '#0E4D25' : '#5B5970'), border: broke ? '#B42318' : 'transparent' };
    });
    const retry = () => {
      let r;
      if (b.kind === 'ok') r = 'You already have a definite answer. A retry here would be a second, separate charge.';
      else if (b.kind === 'not') r = 'Retried. Charged exactly once. NotSent made this safe with or without a key.';
      else if (st.useKey) r = b.charged ? 'Retried with the same key. The provider recognised it and returned the original result: charged exactly once.' : 'Retried with the key. The provider had nothing under that key, so it charged now: exactly once.';
      else r = b.charged ? 'Retried without a key. The provider saw a brand-new request: the customer is now charged TWICE.' : 'Retried without a key and got lucky: charged once. Next time you might not be.';
      this.setState({ retryResult: r });
    };
    const evTone = b.kind === 'ok' ? ['#E2F4E7', '#B9E2C4'] : b.kind === 'not' ? ['#E0E9FD', '#B8CBF7'] : ['#FFF1C2', '#F0D277'];

    // define once
    const D = [
      { label: 'JSON codec', pkg: 'JSON Blueprint', name: 'Codec(User)', tint: '#DDF3F0', ink: '#0B4A45', what: 'One description of a data shape: its fields, which are optional, which numbers are allowed.', uses: [['encode', 'turns a Gleam value into JSON'], ['decode', 'admits JSON strictly, with a path to every error'], ['schema', 'publishes a JSON Schema for the same shape'], ['others', 'LLM Wire, Relay and Fabric reuse codecs for structured answers and tool arguments']] },
      { label: 'Telemetry event', pkg: 'Sinal', name: 'Event(measurements, metadata)', tint: '#DDF3F0', ink: '#0B4A45', what: 'A named event with typed fields, shared between the code that emits it and the code that observes it.', uses: [['producer', 'emits typed values'], ['observer', 'receives the same typed values'], ['Erlang/Elixir', 'native :telemetry handlers see ordinary names and maps'], ['spans', 'start, stop and exception events around a piece of work']] },
      { label: 'MCP tool', pkg: 'Relay', name: 'tool.Definition(input, output)', tint: '#EEE7FD', ink: '#3B1785', what: 'A tool’s name, description and input and output codecs.', uses: [['server', 'declares the tool and runs your handler'], ['client', 'calls it and gets a typed result back'], ['discovery', 'peers see the generated schema'], ['agents', 'a Fabric agent can mount it as a tool']] },
      { label: 'Job worker', pkg: 'Grind', name: 'Worker(input, output, error)', tint: '#FDF0DC', ink: '#6B3404', what: 'A named job type with codecs for its input, output and error.', uses: [['submit', 'enqueue a typed input, now or later'], ['perform', 'your handler receives the decoded input'], ['storage', 'a versioned contract; changed codecs show up as ContractMismatch'], ['await', 'read a typed outcome back']] },
      { label: 'Decision point', pkg: 'Decisions', name: 'Point(output)', tint: '#FCE7F3', ink: '#5E0B3A', what: 'Where a recommendation becomes a released output: the output’s codec and the facts a policy may read.', uses: [['policy', 'versioned rules read only the declared facts'], ['card', 'a person sees what the model saw'], ['gated tool', 'accepts nothing but a released output'], ['learning', 'tallies agreement per recommender version']] }
    ];
    const defs = D.map((d, i) => ({ label: d.label, cls: st.def === i ? 'on' : '', pick: () => this.setState({ def: i }) }));
    const dd = D[st.def];
    const def = Object.assign({}, dd, { uses: dd.uses.map((u) => ({ who: u[0], does: u[1] })) });

    // bounds
    const F = st.firstS, G = st.gapS, T = st.totalS;
    const trips = [];
    if (F > 180) trips.push([180, 'First-progress timeout (180 s)', 'Nothing useful arrived within 180 seconds, so the call ended early instead of waiting the full 600.']);
    if (G > 60) trips.push([Math.max(F, 0) + 60, 'Idle-gap timeout (60 s)', 'The stream went quiet for over a minute mid-answer. A stalled stream is treated as a failure, not waited on forever.']);
    if (T > 600) trips.push([600, 'Whole-call timeout (600 s)', 'Each chunk came in time, but the call as a whole ran past ten minutes.']);
    trips.sort((a, x) => a[0] - x[0]);
    const tripped = trips[0];
    const sliderVal = (e) => Number(e && e.target ? e.target.value : e);

    const qs = [
      { q: 'A payment call returns MaybeSent. What’s the safe next move?',
        o: ['Retry immediately; the first one probably failed', 'Retry with the same idempotency key, or check with the provider first', 'Assume it failed and tell the customer'], c: 1,
        e: 'MaybeSent means the effect may already have happened. An idempotency key turns a retry into "do it if you haven’t", and reconciliation asks the provider directly.' },
      { q: 'A Sinal event says a job finished, but its Grind row says Retryable. Which do you trust?',
        o: ['The Sinal event; it’s more recent', 'The Grind row: durable records are the truth', 'Neither; restart the node'], c: 1,
        e: 'Telemetry is best effort and can be dropped or out of order. Durable rows are the source of job outcomes.' },
      { q: 'Where does "only finance leads may approve refunds over €500" live?',
        o: ['Inside Fabric’s source code', 'In a Decisions configuration file shipped with the library', 'In your application’s policy, handed to the library'], c: 2,
        e: 'Policy is an application decision. Fabric and Decisions take your policy as a value and enforce it; they never invent one.' }
    ];
    return Object.assign({
      habits, habit,
      sortItems, sortScore: done ? right + ' / ' + done + ' right' : '0 / 12 sorted', resetSort: () => this.setState({ sorted: {} }),
      breakOpts, journey, evidence: b.ev, evidenceWhy: b.evWhy, evBg: evTone[0], evBorder: evTone[1], truth: b.truth, safeMove: b.safe,
      revealed: st.revealed, hidden: !st.revealed, reveal: () => this.setState({ revealed: true }),
      keyLabel: st.useKey ? 'Idempotency key: on' : 'Idempotency key: off', keyCls: st.useKey ? 'btn on' : 'btn', toggleKey: () => this.setState({ useKey: !st.useKey }),
      retry, retryResult: st.retryResult,
      defs, def,
      firstS: F, gapS: G, totalS: T,
      setFirst: (e) => this.setState({ firstS: sliderVal(e) }), setGap: (e) => this.setState({ gapS: sliderVal(e) }), setTotal: (e) => this.setState({ totalS: sliderVal(e) }),
      boundTitle: tripped ? 'Stopped: ' + tripped[1] : 'Completed within every bound',
      boundWhy: tripped ? tripped[2] + ' You get a typed failure naming the bound, plus advice on whether another attempt might help.' : 'First progress, every gap and the total all stayed inside the defaults. Each one is configurable per call.',
      boundBg: tripped ? '#FFF1C2' : '#E2F4E7', boundFg: tripped ? '#5C4300' : '#0E4D25'
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
