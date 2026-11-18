class Component extends DCLogic {
  constructor(props) { super(props); this.state = { answers: {}, strat: 'det', priv: true, pos: 6, q: '', gtag: 'all' }; }
  renderVals() {
    const st = this.state;
    // ---------- Retrace ----------
    const EV = [['open cart', 'msg'], ['add Book', 'msg'], ['add Mug', 'msg'], ['coupon SAVE10', 'ext'], ['type email', 'msg'], ['checkout', 'msg']];
    const pos = st.pos;
    const items = [];
    if (pos >= 2) items.push({ name: 'Book', price: '€12' });
    if (pos >= 3) items.push({ name: 'Mug', price: '€8' });
    const sub = items.reduce((a, b) => a + Number(b.price.slice(1)), 0);
    const coupon = pos >= 4;
    const disc = coupon ? Math.round(sub * 0.1 * 100) / 100 : 0;
    const emailTyped = pos >= 5;
    const email = !emailTyped ? '(empty)' : (st.priv ? '•••• (excluded at capture)' : 'ada@example.com');
    const status = pos === 0 ? 'nothing recorded yet' : pos >= 6 ? 'checked out' : 'shopping';
    const events = EV.map((e, i) => ({ n: i + 1, label: e[0], bg: i < pos ? (e[1] === 'ext' ? '#FFF1C2' : '#E2F4E7') : '#F1EEE8', fg: i < pos ? '#17162B' : '#8A8698' }));
    let how;
    if (st.strat === 'det') how = 'Deterministic replay: the recorded safe messages, including the coupon service’s answer (an external result), were fed through the same pure update function, and the view rendered from the result. It needs the exact build that recorded it.';
    else how = 'Protected-observation replay: after each transition the app recorded validated observations, the presence of values and the decisions it accepted, and the replay adopts them instead of re-running logic. It also needs the exact build.';
    how += st.priv ? ' The email was classified private and excluded at capture, so no viewer setting can bring it back. Privacy is decided by your app before anything is stored.' : ' The email was recorded because your app classified it as safe. Viewer redaction alone can never make a recording private.';

    // ---------- glossary ----------
    const G = [
      ['Process', 'BEAM', 'A tiny isolated unit of work with its own memory. Millions can run at once.'],
      ['Mailbox', 'BEAM', 'The queue of messages a process handles one at a time.'],
      ['Link', 'BEAM', 'Ties two processes’ fates: when one dies, the other gets an exit signal.'],
      ['Monitor', 'BEAM', 'A one-way watch: you get a message when the other process goes down.'],
      ['Preemptive scheduling', 'BEAM', 'Every process gets a small work budget, then must step aside.'],
      ['Actor', 'OTP', 'A process with private state that handles messages in a loop (gen_server).'],
      ['Supervisor', 'OTP', 'Starts children and restarts them by strategy; escalates if restarts happen too often.'],
      ['Restart strategy', 'OTP', 'One for one, one for all, or rest for one: which children restart together.'],
      ['Subject', 'Gleam', 'A typed address: it only accepts messages of one type.'],
      ['Result', 'Gleam', 'Ok(value) or Error(reason): failure as an ordinary value.'],
      ['Custom type', 'Gleam', 'A type with variants, each carrying exactly the data its case needs.'],
      ['Codec', 'JSON Blueprint', 'One definition that encodes, strictly decodes and publishes a JSON Schema.'],
      ['Forwarder', 'Sinal', 'A bounded process that runs observers off the hot path; drops and counts when full.'],
      ['Destination policy', 'HTTP Gun', 'Rules on where a client may connect, checked against resolved addresses.'],
      ['Cassette', 'HTTP Gun', 'A recorded set of exchanges replayed offline in tests, with secrets redacted.'],
      ['NotSent', 'principle', 'Provably never left your machine. Safe to retry.'],
      ['MaybeSent', 'principle', 'May have reached the other side. Retry only with an idempotency key, or reconcile.'],
      ['Idempotency key', 'principle', 'A stable id for an effect so a repeat is recognised and not done twice.'],
      ['Reconcile', 'principle', 'Ask an authoritative source what really happened, then record it.'],
      ['Prepare', 'LLM Wire', 'Validate and encode a request with no network, before spending tokens.'],
      ['Verifier', 'Relay', 'Your function that decides whether a bearer token is admitted.'],
      ['Token custody', 'Hellhound', 'Keeping a user’s tokens safe and refreshed under an opaque session.'],
      ['Sender', 'Correio', 'An injected function that delivers a message: SMTP, Postmark or a test capture.'],
      ['Lease', 'Grind', 'A time-limited database claim on a job, so only one node runs it.'],
      ['Transactional admission', 'Grind', 'Submitting a job inside your own transaction: both commit or neither.'],
      ['Uncertain', 'Grind', 'A job whose effect is unknown; it waits for an audited resolution.'],
      ['Compensation', 'Saga', 'Undoing known completed steps, newest first, when a later step fails.'],
      ['Hold', 'Saga', 'Pausing a run whose effect can’t be proven, for your app to reconcile.'],
      ['Checkpoint', 'Saga', 'Saved progress that lets a durable run resume after a crash.'],
      ['Policy gate', 'Fabric', 'Your function deciding Allow, Deny, RequireApproval or HandOver for each action.'],
      ['HandOver', 'Fabric', 'The action belongs to another system; the run ends and the tool never runs.'],
      ['Store', 'Fabric', 'Keeps run records and supervises runners; memory, directory or PostgreSQL.'],
      ['Decision point', 'Decisions', 'Where a recommendation must pass policy, and maybe a person, before release.'],
      ['Occurrence', 'Decisions', 'One recommendation about one subject, kept as append-only entries.'],
      ['Undo window', 'Decisions', 'A hold before release during which a decider may withdraw.'],
      ['Release', 'Decisions', 'Handing the final output to the gated tool, at most once.'],
      ['Protected observation', 'Retrace', 'A replay strategy that adopts recorded, validated observations.']
    ];
    const TAGC = { BEAM: ['#EBEAFD', '#2B2862'], OTP: ['#DCD9FF', '#241F6B'], Gleam: ['#F9D7F0', '#4A1340'], principle: ['#17162B', '#FFFFFF'] };
    const tagColor = (t) => TAGC[t] || (['JSON Blueprint', 'Sinal'].indexOf(t) >= 0 ? ['#DDF3F0', '#0B4A45'] : t === 'HTTP Gun' ? ['#E0E9FD', '#163A8A'] : ['LLM Wire', 'Relay', 'Hellhound', 'Correio'].indexOf(t) >= 0 ? ['#EEE7FD', '#3B1785'] : ['Grind', 'Saga'].indexOf(t) >= 0 ? ['#FDF0DC', '#6B3404'] : ['Fabric', 'Decisions'].indexOf(t) >= 0 ? ['#FCE7F3', '#5E0B3A'] : ['#E2F4E7', '#0E4D25']);
    const q = (st.q || '').toLowerCase();
    const GT = [['all', 'All'], ['runtime', 'BEAM · OTP · Gleam'], ['principle', 'Principles'], ['libs', 'Libraries']];
    const inTag = (t) => st.gtag === 'all' || (st.gtag === 'runtime' ? ['BEAM', 'OTP', 'Gleam'].indexOf(t) >= 0 : st.gtag === 'principle' ? t === 'principle' : ['BEAM', 'OTP', 'Gleam', 'principle'].indexOf(t) < 0);
    const terms = G.filter((g) => inTag(g[1]) && (!q || (g[0] + ' ' + g[2] + ' ' + g[1]).toLowerCase().indexOf(q) >= 0)).map((g) => ({ term: g[0], tag: g[1], def: g[2], bg: tagColor(g[1])[0], fg: tagColor(g[1])[1] }));
    const gtags = GT.map((t) => ({ label: t[1], cls: 'btn sm' + (st.gtag === t[0] ? ' on' : ''), pick: () => this.setState({ gtag: t[0] }) }));

    // ---------- cheat sheet ----------
    const SH = [
      ['Sinal', 'report typed facts and observe them, or keep slow observers off the hot path', 'best effort; names are atoms; no exporter included', '#DDF3F0', '#0B4A45'],
      ['JSON Blueprint', 'describe a JSON shape once: encode, strict decode, schema', 'errors carry JSON paths; byte limits for untrusted text', '#DDF3F0', '#0B4A45'],
      ['HTTP Gun', 'call HTTP APIs with pooling, limits, streaming and test cassettes', 'never retries; NotSent / MaybeSent; loopback is opt-in', '#E0E9FD', '#163A8A'],
      ['LLM Wire', 'make one typed, bounded model call; structured output; classification', 'you own history, tool execution and retries', '#EEE7FD', '#3B1785'],
      ['Relay', 'expose typed tools over MCP, or call an MCP server', 'outcomes: succeeded, refused, needs input; your verifier', '#EEE7FD', '#3B1785'],
      ['Hellhound', 'sign users in with OIDC, hold OAuth tokens, validate JWTs', 'pre-production; accounts and cookies are yours', '#EEE7FD', '#3B1785'],
      ['Correio', 'send transactional mail; magic links and email codes', 'four outcomes; no outbox: pair with Grind', '#EEE7FD', '#3B1785'],
      ['Grind', 'run durable background jobs on PostgreSQL', 'submit in your transaction; rows are the truth', '#FDF0DC', '#6B3404'],
      ['Saga', 'run dependent steps with retries, undo and checkpoints', 'undoes only known successes; holds the unknown', '#FDF0DC', '#6B3404'],
      ['Fabric', 'run a bounded agent or durable graph behind a policy gate', 'handles don’t own runs; uncertain effects block', '#FCE7F3', '#5E0B3A'],
      ['Decisions', 'gate an output with versioned policy and people, release once', 'Git-only for now; autonomy grows by data', '#FCE7F3', '#5E0B3A'],
      ['Retrace', 'record and replay a Lustre session from typed events', 'experimental; privacy decided at capture', '#E2F4E7', '#0E4D25']
    ];
    const sheet = SH.map((r) => ({ name: r[0], when: r[1], remember: r[2], bg: r[3], fg: r[4] }));
    const val = (e) => (e && e.target ? e.target.value : e);

    const qs = [
      { q: 'What makes "let it crash" a safe strategy on the BEAM?', o: ['Crashes are rare in Gleam', 'Isolated processes plus supervisors that restart from a known state', 'The VM catches every exception'], c: 1, e: 'Isolation contains the failure; supervision recovers from it. Modules 1 and 2.' },
      { q: 'A payment call fails with MaybeSent. What next?', o: ['Retry right away', 'Retry with the same idempotency key, or reconcile with the provider', 'Report failure to the customer'], c: 1, e: 'MaybeSent means it may have happened. Module 4.' },
      { q: 'A confirmation email must go out only if the order really committed, even across a crash. What fits?', o: ['Send it with Correio right after the insert', 'Submit a Grind job in the same transaction; the job sends it with Correio', 'Emit a Sinal event and send from the observer'], c: 1, e: 'Transactional admission plus a durable job. Telemetry is best effort and never a delivery mechanism. Modules 7 and 8.' },
      { q: 'You want to see slow HTTP calls across every library at once. Where do you look?', o: ['Each library’s logs separately', 'Attach Sinal observers to their lifecycle events', 'Wrap every call in a timer by hand'], c: 1, e: 'Most libraries emit Sinal events, so one set of observers sees all of them. Module 6.' },
      { q: 'A model’s answer must match an exact shape, with numbers in range. What do you use?', o: ['Parse the text with a regex', 'A JSON Blueprint codec as LLM Wire’s structured output', 'Ask the model to be careful'], c: 1, e: 'The codec is the schema the model sees and the decoder that checks it. Modules 6 and 7.' },
      { q: 'An agent may propose wire transfers but must never execute one on its own. What’s the design?', o: ['Tell the model in its prompt not to', 'Fabric policy hands the call over to a Decisions point; release happens once, after policy and people', 'Give the tool a very low timeout'], c: 1, e: 'Prompts aren’t policy. The gate and the decision point are. Module 9.' },
      { q: 'Support wants to see exactly what a user did in your Lustre app yesterday. What helps?', o: ['Retrace', 'Saga', 'Relay'], c: 0, e: 'Retrace reconstructs a session from recorded typed events, within the privacy your app decided at capture.' },
      { q: 'Who owns the PostgreSQL connection pool in a system using Grind, Saga and Fabric?', o: ['Grind, since it needs PostgreSQL most', 'Each library opens its own', 'Your application; libraries borrow it'], c: 2, e: 'Libraries own mechanisms; your application owns resources and lifetimes. Module 4.' }
    ];
    return Object.assign({
      strategies: [['det', 'Deterministic'], ['prot', 'Protected observations']].map((s) => ({ label: s[1], cls: st.strat === s[0] ? 'on' : '', pick: () => this.setState({ strat: s[0] }) })),
      privLabel: st.priv ? 'Email: private (excluded)' : 'Email: safe to record', privCls: st.priv ? 'btn on' : 'btn', togglePriv: () => this.setState({ priv: !st.priv }),
      pos, setPos: (e) => this.setState({ pos: Number(val(e)) }), events,
      cart: items.length ? items : [{ name: 'empty', price: '' }], discountLabel: coupon ? 'Coupon SAVE10' : 'No coupon', discount: coupon ? '−€' + disc : '', total: '€' + (sub - disc), email, status, how,
      q: st.q, setQ: (e) => this.setState({ q: val(e) }), gtags, terms, termCount: terms.length + ' of ' + G.length + ' terms',
      sheet
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
