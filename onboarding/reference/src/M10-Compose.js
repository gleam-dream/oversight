class Component extends DCLogic {
  constructor(props) { super(props); this.state = { answers: {}, sys: 0, cur: 1, need: { durable: true, steps: true } }; }
  componentWillUnmount() { clearInterval(this.anim); }
  renderVals() {
    const st = this.state;
    const LIB = {
      sinal: ['Sinal', '#DDF3F0', '#0B4A45'], blueprint: ['JSON Blueprint', '#DDF3F0', '#0B4A45'], http_gun: ['HTTP Gun', '#E0E9FD', '#163A8A'],
      llm_wire: ['LLM Wire', '#EEE7FD', '#3B1785'], relay: ['Relay', '#EEE7FD', '#3B1785'], hellhound: ['Hellhound', '#EEE7FD', '#3B1785'], correio: ['Correio', '#EEE7FD', '#3B1785'],
      grind: ['Grind', '#FDF0DC', '#6B3404'], saga: ['Saga', '#FDF0DC', '#6B3404'], fabric: ['Fabric', '#FCE7F3', '#5E0B3A'], decisions: ['Decisions', '#FCE7F3', '#5E0B3A'], retrace: ['Retrace', '#E2F4E7', '#0E4D25'],
      app: ['Your app', '#F1EEE8', '#17162B']
    };
    const S = (pkg, text) => ({ pkg, text });
    const SYS = [
      { name: 'Checkout', task: 'Reserve, charge, ship', pk: ['saga', 'grind', 'http_gun', 'sinal'],
        blurb: 'An order API. The checkout saga reserves stock, charges a payment token and books a shipment, compensating in reverse on failure. A durable mode runs the same saga from a Grind job.',
        steps: [S('app', 'POST /orders. The server prices the order from its own catalog; a body that carries an amount is refused.'), S('grind', 'Durable mode: the order row and a job are written in one transaction.'), S('grind', 'A worker claims the job and drives the checkout saga by a stable id.'), S('saga', 'Reserve stock, charge the token with an idempotency key, book the shipment.'), S('http_gun', 'Every provider call goes through HTTP Gun, with send evidence on failure.'), S('saga', 'On failure, undo completed steps in reverse. An uncertain charge is held, never guessed.'), S('sinal', 'Grind, Saga and HTTP Gun emit lifecycle events to your observers.')],
        why: 'Grind makes the work survive restarts; Saga gives it order and undo. Neither alone covers both.', owns: 'Pricing, authentication, payment tokens, the orders table and stable error codes.' },
      { name: 'Webhooks', task: 'Deliver signed events', pk: ['grind', 'http_gun', 'sinal'],
        blurb: 'A multi-tenant outbound webhook service: one event fans out to one durable job per subscription.',
        steps: [S('app', 'A tenant registers endpoint URLs. Its API key, never the request body, decides which tenant it is.'), S('grind', 'Publishing an event fans out to one Grind job per active subscription.'), S('http_gun', 'The worker signs the delivery and sends it under a per-tenant destination policy.'), S('grind', 'The HTTP result maps to a Grind retry, snooze, discard or failure.'), S('app', 'The delivery id travels on every retry as the receiver’s idempotency key.')],
        why: 'Each delivery is an independent unit that must survive restarts: exactly a Grind job. HTTP Gun’s evidence decides how to retry it.', owns: 'Signing, tenant isolation, and mapping statuses to retry decisions.' },
      { name: 'Invoice extractor', task: 'Documents in, typed invoices out', pk: ['grind', 'http_gun', 'llm_wire', 'blueprint', 'sinal'],
        blurb: 'Batch extraction: each document URL becomes a job that fetches it, asks a model for a typed Invoice, and stores the result.',
        steps: [S('grind', 'A batch of document URLs becomes a batch of Grind jobs.'), S('http_gun', 'Each job fetches its document as a bounded stream. An oversized one is refused.'), S('llm_wire', 'One structured-output call asks for an Invoice.'), S('blueprint', 'The Invoice codec is both the schema the model sees and the decoder that checks it.'), S('app', 'Business rules check it: a total that contradicts its lines, an unknown currency.'), S('grind', 'A rate-limited call follows LLM Wire’s retry advice and becomes a job retry.')],
        why: 'One job per document isolates failures. The codec turns a model’s answer into a Gleam value or a precise error.', owns: 'Invoice rules, the retry policy and storage.' },
      { name: 'Tool hub', task: 'MCP in both directions', pk: ['relay', 'fabric', 'llm_wire', 'blueprint', 'http_gun', 'sinal'],
        blurb: 'An inventory MCP server, a Fabric agent that uses it, and a second MCP server that exposes the agent itself as a tool.',
        steps: [S('relay', 'An inventory server exposes three typed tools.'), S('fabric', 'A Fabric agent mounts them through the Relay client.'), S('fabric', 'Its policy runs only tools the inventory declares read-only. reserve_stock waits for the operator.'), S('relay', 'A second Relay server exposes the agent as the tool ask_assistant.'), S('app', 'The operator approves or rejects; the caller repeats its keyed call to read the answer.')],
        why: 'A question is untrusted model input, so read-only hints become policy, and anything that changes stock waits for a person.', owns: 'Which tools are safe, the operator credential and the approval step.' },
      { name: 'Secure MCP', task: 'Tools that act for a user', pk: ['relay', 'hellhound', 'grind', 'blueprint', 'http_gun', 'sinal'],
        blurb: 'An MCP server whose report tools act for a signed-in user, with long reports running as jobs.',
        steps: [S('hellhound', 'The user signs in through OpenID Connect.'), S('app', 'POST /me/token hands them an access token to paste into an MCP client.'), S('relay', 'Relay’s protected endpoint shares the web listener; its verifier validates the token.'), S('grind', 'generate_report and report_status run as Grind jobs owned by the authenticated subject.'), S('app', 'No token, another user’s job, wrong audience, forged or revoked token: each one is refused.')],
        why: 'Identity from Hellhound, protocol from Relay, long work from Grind. Who may see which job stays an app check.', owns: 'Mapping subjects to permissions and checking job ownership.' },
      { name: 'Support desk', task: 'Approve and execute refunds', pk: ['fabric', 'saga', 'llm_wire', 'hellhound', 'blueprint', 'http_gun', 'sinal'],
        blurb: 'A customer-support agent with typed tools for order lookup, refund eligibility and refunds.',
        steps: [S('hellhound', 'Each ticket’s session names the customer the application authenticated.'), S('fabric', 'The agent looks up only that customer’s orders.'), S('fabric', 'A refund waits for a human approver at the policy gate.'), S('saga', 'Approved refunds run as a saga: refund through the payment API, write a ledger entry, notify the customer.'), S('saga', 'Its first step re-checks: the order is theirs, delivered, and the amount fits.'), S('fabric', 'The agent finishes with a typed Resolution.')],
        why: 'A customer’s message can steer the model, so approval isn’t the only guard: the workflow re-validates before money moves.', owns: 'Ownership checks, refund limits and an idempotency key naming order and amount.' },
      { name: 'Research agent', task: 'Resume after a crash, publish', pk: ['grind', 'fabric', 'saga', 'llm_wire', 'http_gun', 'blueprint', 'sinal'],
        blurb: 'A research agent that survives a VM restart mid-run and publishes through a compensating workflow.',
        steps: [S('grind', 'start_research records the request and enqueues a job in one transaction.'), S('fabric', 'The job runs an agent with search and read tools.'), S('fabric', 'Its policy parses every URL the model picks and admits only one host and path prefix.'), S('fabric', 'Every turn is checkpointed in PostgreSQL, so a restart resumes the run.'), S('saga', 'A durable saga publishes the article, with compensation.')],
        why: 'Three clear authorities: Grind owns delivery, Fabric owns the agent run, Saga owns the publish.', owns: 'The URL policy, the publish target and cancellation.' },
      { name: 'Clinic registration', task: 'A patient record from a chat', pk: ['decisions', 'llm_wire', 'grind', 'blueprint', 'http_gun', 'sinal'],
        blurb: 'Patient registration from a messaging conversation, through a decision point on PostgreSQL.',
        steps: [S('decisions', 'A message arrives as a trigger. Admitting it supersedes older work for the same contact and records that a recommendation is expected.'), S('llm_wire', 'One structured-output call recommends a patient record.'), S('decisions', 'A stored, versioned policy decides: v1 asks reception; v2 lets a sure registration proceed after a ten-minute undo window.'), S('grind', 'Grind delivers wake-ups and settlement notices.'), S('decisions', 'The record is released once to the gated registration tool.')],
        why: 'A late model answer for an older message writes nothing, because the newer one superseded it.', owns: 'Patient record rules, the reception roster and the messaging channel.' },
      { name: 'Payout desk', task: 'Agent proposes, finance decides', pk: ['fabric', 'decisions', 'relay', 'saga', 'grind', 'hellhound', 'blueprint', 'sinal'],
        blurb: 'A marketplace pays its sellers. The agent investigates; a decision point decides; a saga pays.',
        steps: [S('fabric', 'A support agent investigates a disputed order and proposes a payout.'), S('fabric', 'The policy hands the propose_payout call over. The run ends; nothing is paid.'), S('decisions', 'The payout point applies versioned policy: small won disputes proceed after an undo window; from 500.00 it takes two from finance.'), S('relay', 'The decision desk is served over MCP.'), S('saga', 'A release check compares the amount to the seller’s balance, then the payout runs as a saga.')],
        why: 'Fabric never moves money. A decision point owns the "should we", a saga owns the "how".', owns: 'Who is in finance, balance rules and suspensions that supersede pending payouts.' },
      { name: 'Moderation desk', task: 'Moderate posts at volume', pk: ['decisions', 'blueprint', 'sinal'],
        blurb: 'Moderation with no database: the decisions OTP runtime works through posts with a bounded pool of workers.',
        steps: [S('decisions', 'Posts arrive as triggers for the moderation point.'), S('decisions', 'A rule model and a classifier, each isolated with a deadline, recommend publish, hide or escalate.'), S('decisions', 'Versioned policies let confident answers through and ask moderators or seniors about the rest; a sample is reviewed.'), S('decisions', 'Policy v2 holds a confident spam hide for five minutes; a senior may take it back.'), S('sinal', 'A replay gates each new policy version, and Sinal counts what an operator needs to see.')],
        why: 'All of BEAM’s strengths in one place: isolated model processes, live desks, and a supervised runtime.', owns: 'The rules, the moderator roster and which samples to review.' }
    ];
    const sys = SYS[st.sys];
    const N = sys.steps.length, cur = Math.min(st.cur, N);
    const curPkg = sys.steps[cur - 1].pkg;
    const systems = SYS.map((s, i) => ({ name: s.name, task: s.task, bg: st.sys === i ? '#17162B' : '#FFFFFF', fg: st.sys === i ? '#FFFFFF' : '#17162B', border: st.sys === i ? '#17162B' : '#E4E0D8',
      pick: () => { clearInterval(this.anim); this.setState({ sys: i, cur: 1 }); } }));
    const chips = ['sinal', 'blueprint', 'http_gun', 'llm_wire', 'relay', 'hellhound', 'correio', 'grind', 'saga', 'fabric', 'decisions', 'retrace'].map((k) => {
      const used = sys.pk.indexOf(k) >= 0, now = k === curPkg;
      return { name: LIB[k][0], bg: used ? LIB[k][1] : '#FFFFFF', fg: LIB[k][2], border: now ? LIB[k][2] : (used ? LIB[k][1] : '#E4E0D8'), op: used ? 1 : 0.35 };
    });
    const flow = sys.steps.map((s, i) => ({ n: i + 1, pkg: LIB[s.pkg][0], cbg: LIB[s.pkg][1], cfg: LIB[s.pkg][2], text: s.text,
      bg: i === cur - 1 ? '#FFFFFF' : '#FAF8F4', border: i === cur - 1 ? '#17162B' : '#E4E0D8', op: i < cur ? 1 : 0.3 }));
    const playAll = () => {
      clearInterval(this.anim);
      if (!GD.motion()) { this.setState({ cur: SYS[this.state.sys].steps.length }); return; }
      this.setState({ cur: 1 });
      this.anim = setInterval(() => {
        const n = SYS[this.state.sys].steps.length;
        if (this.state.cur >= n) { clearInterval(this.anim); return; }
        this.setState({ cur: this.state.cur + 1 });
      }, 1300);
    };

    const chain = (ks) => ks.map((k, i) => ({ name: LIB[k][0], bg: LIB[k][1], fg: LIB[k][2], arrow: i < ks.length - 1 ? '→' : '' }));
    const patterns = [
      { name: 'Transactional enqueue', chain: chain(['app', 'grind']), text: 'Write your row and submit the job in one transaction. Both exist or neither does: the outbox pattern, built in.' },
      { name: 'A job drives a saga', chain: chain(['grind', 'saga']), text: 'Grind redelivers after a crash; the saga reconnects by id and resumes from its checkpoint.' },
      { name: 'Typed model call', chain: chain(['llm_wire', 'blueprint', 'http_gun']), text: 'A codec describes the answer, LLM Wire makes one bounded call, and you get a Gleam value or a precise error.' },
      { name: 'Agent with gated tools', chain: chain(['fabric', 'llm_wire', 'relay']), text: 'Fabric runs the loop on LLM Wire; tools can come from MCP servers through Relay. Policy sees every call.' },
      { name: 'Hand over to a decision point', chain: chain(['fabric', 'decisions', 'saga']), text: 'The agent proposes, a decision point decides with policy and people, and a saga performs the effect once.' },
      { name: 'Protected tools, long work', chain: chain(['hellhound', 'relay', 'grind']), text: 'Hellhound validates tokens, Relay admits the caller, Grind runs long work owned by that subject.' }
    ];

    // builder
    const REQ = [
      ['http', 'Call other services over HTTP', ['http_gun']],
      ['model', 'Get typed answers from an LLM', ['llm_wire', 'blueprint', 'http_gun']],
      ['agent', 'Let a model use tools in a loop', ['fabric', 'llm_wire', 'http_gun']],
      ['mcp', 'Expose tools to AI agents (MCP)', ['relay', 'blueprint']],
      ['auth', 'Sign users in or protect an API with tokens', ['hellhound', 'http_gun']],
      ['email', 'Send email or magic links', ['correio']],
      ['durable', 'Run work in the background, surviving restarts', ['grind']],
      ['steps', 'Multi-step operations that can be undone', ['saga']],
      ['human', 'Have a person approve some outputs', ['decisions']],
      ['replay', 'Replay what users did in a Lustre UI', ['retrace']]
    ];
    const WHY = { http_gun: 'one bounded client for every outbound call', llm_wire: 'typed, bounded provider calls', blueprint: 'codecs for answers, tool arguments and schemas', fabric: 'the agent loop, policy gate and run records', relay: 'MCP server and client', hellhound: 'OIDC sign-in, tokens and JWT checks', correio: 'mail delivery and passwordless challenges', grind: 'durable jobs on PostgreSQL', saga: 'ordered steps with undo and checkpoints', decisions: 'policy, approvals and release at most once', retrace: 'typed recording and inert replay', sinal: 'comes along: attach observers to see inside all of the above' };
    const nd = st.need;
    const sel = {};
    REQ.forEach((r) => { if (nd[r[0]]) r[2].forEach((p) => (sel[p] = true)); });
    if (Object.keys(sel).some((k) => ['http_gun', 'grind', 'saga', 'fabric', 'relay', 'hellhound', 'decisions', 'llm_wire'].indexOf(k) >= 0)) sel.sinal = true;
    const order = ['sinal', 'blueprint', 'http_gun', 'llm_wire', 'relay', 'hellhound', 'correio', 'grind', 'saga', 'fabric', 'decisions', 'retrace'];
    const picked = order.filter((k) => sel[k]).map((k) => ({ name: LIB[k][0], why: WHY[k], bg: LIB[k][1], fg: LIB[k][2] }));
    const reqs = REQ.map((r) => ({ label: r[1], on: !!nd[r[0]], mark: nd[r[0]] ? '✓' : '+', bg: nd[r[0]] ? '#FFF7FC' : '#FFFFFF', border: nd[r[0]] ? '#B0186E' : '#E4E0D8',
      toggle: () => this.setState({ need: Object.assign({}, nd, { [r[0]]: !nd[r[0]] }) }) }));
    const applies = [];
    if (nd.durable && nd.email) applies.push('Send email from a Grind job submitted in the same transaction as your write. Correio has no outbox of its own.');
    if (nd.durable && nd.steps) applies.push('A job drives a durable saga (checkout, financial recovery).');
    if (nd.agent && nd.human) applies.push('Fabric hands risky calls over to a Decisions point (payout desk).');
    if (nd.agent && nd.mcp) applies.push('Mount MCP tools in a Fabric agent through Relay, or serve the agent itself as a tool (tool hub).');
    if (nd.mcp && nd.auth) applies.push('Back Relay’s verifier with Hellhound token validation (secure MCP).');
    if (nd.model && nd.durable && !nd.agent) applies.push('One Grind job per document; LLM Wire’s retry advice becomes a job retry (extractor).');
    if (nd.human && nd.model && !nd.agent) applies.push('One LLM Wire call recommends; a decision point decides (clinic registration).');
    if (nd.agent && nd.steps) applies.push('Run approved effects as a saga that re-validates and can undo (support desk).');
    if (nd.agent && nd.durable) applies.push('Start agent runs from jobs and keep the Fabric store in PostgreSQL to survive restarts (research agent).');
    if (!applies.length && nd.durable) applies.push('Submit jobs in the same transaction as the write that caused them.');
    const APPS = [['Checkout', ['saga', 'grind', 'http_gun']], ['Financial recovery', ['saga', 'grind', 'http_gun']], ['Webhooks', ['grind', 'http_gun']], ['Invoice extractor', ['grind', 'http_gun', 'llm_wire', 'blueprint']], ['Tool hub', ['relay', 'fabric', 'llm_wire', 'blueprint', 'http_gun']], ['Secure MCP', ['relay', 'hellhound', 'grind', 'blueprint', 'http_gun']], ['SSO portal', ['hellhound', 'http_gun']], ['Email portal', ['correio']], ['Support desk', ['fabric', 'saga', 'llm_wire', 'hellhound', 'blueprint', 'http_gun']], ['Research agent', ['grind', 'fabric', 'saga', 'llm_wire', 'http_gun', 'blueprint']], ['Session replay', ['retrace']], ['Clinic registration', ['decisions', 'llm_wire', 'grind', 'blueprint', 'http_gun']], ['Payout desk', ['fabric', 'decisions', 'relay', 'saga', 'grind', 'hellhound', 'blueprint']], ['Moderation desk', ['decisions', 'blueprint']]];
    const mine = Object.keys(sel).filter((k) => k !== 'sinal');
    let best = null, bestScore = 0;
    APPS.forEach((a) => {
      const inter = a[1].filter((x) => mine.indexOf(x) >= 0).length;
      const uni = new Set(a[1].concat(mine)).size;
      const sc = uni ? inter / uni : 0;
      if (sc > bestScore) { bestScore = sc; best = a; }
    });
    const yoursList = ['policy and permissions', 'resource lifetimes: pools, clients, supervisors'];
    if (nd.model || nd.agent) yoursList.push('conversation history and retry budgets');
    if (nd.agent) yoursList.push('each tool’s domain logic');
    if (nd.durable) yoursList.push('the PostgreSQL pool and who runs migrations');
    if (nd.email) yoursList.push('templates');
    if (nd.auth) yoursList.push('accounts and session cookies');
    if (nd.human) yoursList.push('who holds which decision set');
    if (nd.replay) yoursList.push('what is safe to record');
    if (nd.steps || nd.http) yoursList.push('idempotency keys for external effects');

    const qs = [
      { q: 'You need multi-tenant webhook delivery with retries that survive deploys. Which combination fits?',
        o: ['Grind and HTTP Gun', 'Saga and Relay', 'Fabric and LLM Wire'], c: 0,
        e: 'Each delivery is one durable unit: a Grind job. HTTP Gun sends it under a destination policy, and its result maps to retry, snooze or discard.' },
      { q: 'Signed-in users should call your report tools from an AI assistant, and big reports take minutes. Which combination fits?',
        o: ['Relay alone', 'Hellhound, Relay and Grind', 'Correio and Saga'], c: 1,
        e: 'Hellhound for identity and token checks, Relay for MCP, Grind for long work owned by the user. That’s the secure MCP example.' },
      { q: 'A research agent must survive a VM restart and publish its article with compensation. Which three authorities?',
        o: ['LLM Wire, Sinal, Retrace', 'Decisions, Correio, Relay', 'Grind for delivery, Fabric for the run, Saga for the publish'], c: 2,
        e: 'Each package owns one kind of authority, and the application connects them. That’s the research agent example in Oversight.' }
    ];
    return Object.assign({
      systems, sys, chips, flow, cur, total: N, atStart: cur <= 1, atEnd: cur >= N,
      back: () => this.setState({ cur: Math.max(1, cur - 1) }), fwd: () => this.setState({ cur: Math.min(N, cur + 1) }), playAll,
      patterns, reqs, picked, noneYet: !picked.length, applies, noPattern: !applies.length,
      nearest: best ? best[0] : 'Pick a requirement', nearestWhy: best ? 'Shares the most packages with your design. Open it in the Oversight repository.' : '',
      yours: yoursList.join(' · '), clearNeeds: () => this.setState({ need: {} })
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
