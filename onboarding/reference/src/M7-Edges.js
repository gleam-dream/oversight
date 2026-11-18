class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { answers: {}, tab: 'llm', cur: 1, o: { tool: 'yes', allow: 'yes', token: 'valid', result: 'ok', later: 'yes', mode: 'send', outcome: 'Accepted' } };
  }
  flow() {
    const o = this.state.o;
    const S = (a, title, text, owner) => ({ a, title, text, owner });
    if (this.state.tab === 'llm') {
      const steps = [
        S(0, 'Build a request', 'Model, your conversation history, tool declarations and the codec for the answer.', 'app'),
        S(1, 'prepare', 'Validates and encodes. No network. Rejects a schema the provider can’t accept, before you spend a token.', 'lib'),
        S(2, 'run or stream', 'One bounded call through the HTTP Gun client your app started.', 'lib'),
        S(3, 'Generate', 'The provider streams progress: text, tool arguments, usage.', 'ext')
      ];
      if (o.tool === 'yes') {
        steps.push(S(1, 'Tool call admitted', 'The model asked for lookup_order. Its arguments are decoded into your typed value.', 'lib'));
        if (o.allow === 'yes') steps.push(S(0, 'Authorize and run it', 'Your policy says yes. Your code runs the lookup and appends the result to history.', 'app'));
        else steps.push(S(0, 'Refuse it', 'Your policy says no. You append a refusal to history so the model can adapt.', 'app'));
        steps.push(S(0, 'Call again', 'A new request with the longer history: round two. Counting rounds and budgets is your job.', 'app'));
        steps.push(S(3, 'Generate the final answer', 'The provider now answers with what it learned.', 'ext'));
      }
      steps.push(S(1, 'Outcome', 'The answer decoded into your type, plus usage. Or a Failure with send evidence and retry advice.', 'lib'));
      steps.push(S(0, 'Keep the history', 'Store the conversation wherever you like. LLM Wire keeps none of it.', 'app'));
      return { actors: ['Your app', 'LLM Wire', 'HTTP Gun', 'Provider'], steps,
        intro: 'LLM Wire turns one model call into typed values with firm limits. It’s a wire, not an agent: the loop, the history and every tool decision stay in your code. (Fabric, in module 9, is the agent runtime built on top.)',
        takeaway: o.tool === 'yes' ? 'A tool loop is just your code calling LLM Wire repeatedly with a growing history. You authorize every tool call; the library never runs one.' : 'Without tools it’s one prepared call and one typed outcome. Structured output means the answer arrives as your own Gleam type, not text to parse.',
        opts: [['Model asks for a tool', 'tool', ['yes', 'no']]].concat(o.tool === 'yes' ? [['Your policy allows it', 'allow', ['yes', 'no']]] : []) };
    }
    if (this.state.tab === 'relay') {
      const steps = [
        S(0, 'Discover tools', 'The agent lists tools. Each schema comes from the same codecs your handler uses.', 'ext'),
        S(1, 'Admit the request', 'Streamable HTTP request in. Relay builds per-request context' + (o.token === 'valid' ? ' and asks your verifier about the bearer token: accepted.' : ' and asks your verifier about the bearer token: there isn’t one.'), 'lib')
      ];
      if (o.token === 'missing') {
        steps.push(S(0, 'Rejected', 'No valid token, so the request never reaches a handler. Nothing ran.', 'lib'));
      } else {
        steps.push(S(2, 'Order the protocol', 'A runtime actor applies a pure reducer to protocol state, then starts an isolated worker for this call.', 'lib'));
        const r = { ok: ['Return a result', 'Your handler returns a typed output.'], refuse: ['Refuse the call', 'Your handler refuses: say, that order isn’t this caller’s. A refusal is an answer, not a crash.'], input: ['Ask for more input', 'Your handler needs more information, and Relay sends a request for input back to the client.'] }[o.result];
        steps.push(S(3, 'Your handler: ' + r[0], r[1] + ' It sees decoded input and the request context.', 'app'));
        steps.push(S(2, 'Reply', o.result === 'ok' ? 'Succeeded(output), encoded with the same codec.' : o.result === 'refuse' ? 'A tool refusal, distinct from success and from failure.' : 'A request for more input, with what’s needed.', 'lib'));
        steps.push(S(0, 'Typed result', 'A Gleam client gets Succeeded, a refusal or a request for input. Client failures also keep send evidence.', 'ext'));
      }
      return { actors: ['MCP client (agent)', 'Relay transport', 'Relay runtime', 'Your handler'], steps,
        intro: 'MCP is how agents discover and call tools. With Relay, one typed tool definition serves both sides: the server declares and handles it, a client calls it and gets typed values back. The tool hub example even serves a Fabric agent as an MCP tool.',
        takeaway: o.token === 'missing' ? 'Admission happens before any handler runs. Relay asks your verifier; what a valid caller may then do is still your policy.' : 'Each call runs in its own worker, and outcomes come in three honest shapes: succeeded, refused, or needs more input.',
        opts: [['Bearer token', 'token', ['valid', 'missing']]].concat(o.token === 'valid' ? [['Handler', 'result', ['ok', 'refuse', 'input']]] : []) };
    }
    if (this.state.tab === 'hell') {
      const steps = [
        S(0, 'Click "Sign in"', 'The user wants in.', 'ext'),
        S(2, 'Begin login', 'Builds the provider’s authorization address with PKCE (S256), using cached discovery.', 'lib'),
        S(3, 'User signs in', 'At the identity provider you already use. Your app never sees a password.', 'ext'),
        S(1, 'Callback arrives', 'The browser returns with a one-time code. Your route hands it to Hellhound.', 'app'),
        S(2, 'Exchange and check', 'Swaps the code for tokens, verifies signatures with cached keys, checks issuer and audience. You get a checked identity and your own decoded claims.', 'lib'),
        S(1, 'Your account, your cookie', 'Find or create the account by issuer and subject. Set your own session cookie. Tokens stay in Hellhound’s custody.', 'app')
      ];
      if (o.later === 'yes') {
        steps.push(S(1, 'Later: call an API', 'Your app needs the user’s access token for a downstream API.', 'app'));
        steps.push(S(2, 'Refresh near expiry', 'The token is about to expire, so Hellhound refreshes it. Ten requests asking at once share one refresh.', 'lib'));
        steps.push(S(3, 'API checks the token', 'On the API side, Hellhound validates the JWT locally with audience and scope policy.', 'lib'));
      }
      return { actors: ['Browser', 'Your app', 'Hellhound', 'Identity provider'], steps,
        intro: 'Hellhound signs people in through an existing OpenID Connect provider, keeps their tokens, and checks access tokens on your APIs. It is pre-production: real deployments need an independent security review first.',
        takeaway: 'Hellhound proves who someone is and keeps their tokens. Your app decides what an account is, how sessions work and what anyone may do.',
        opts: [['Then call an API', 'later', ['yes', 'no']]] };
    }
    // correio
    if (o.mode === 'send') {
      const out = {
        Accepted: ['The server took responsibility for the message. Not proof it reached an inbox.', 'Record it as sent.'],
        NotSent: ['Provably not sent: the connection failed before the message went out.', 'Safe to retry.'],
        Rejected: ['The server refused it, for example a bad address.', 'Fix the cause; a blind retry will fail again.'],
        OutcomeUnknown: ['The connection broke mid-submission. It may or may not be on its way.', 'Don’t assume either way. Record it and reconcile, or let the user ask again.']
      }[o.outcome];
      return { actors: ['Your app', 'Correio', 'Sender', 'Mail server'], steps: [
        S(0, 'Compose', 'Parse addresses, write text and HTML, add attachments. Building a message sends nothing.', 'app'),
        S(1, 'Admit and render', 'Validates the message and renders MIME.', 'lib'),
        S(2, 'Hand to a sender', 'The Sender is a plain function you inject: SMTP, Postmark, or a capture for tests.', 'app'),
        S(3, 'Submit', 'Bounded SMTP with STARTTLS or implicit TLS.', 'ext'),
        S(1, o.outcome, out[0], 'lib'),
        S(0, 'Decide', out[1], 'app')
      ], intro: 'Correio sends transactional mail through a sender you inject, so swapping SMTP for a test capture is one line. Each send ends in one of four distinct outcomes.',
        takeaway: 'Four outcomes, four different next moves. OutcomeUnknown is the same honesty as MaybeSent from module 4.',
        opts: [['Flow', 'mode', ['send', 'magic link']], ['Outcome', 'outcome', ['Accepted', 'NotSent', 'Rejected', 'OutcomeUnknown']]] };
    }
    return { actors: ['Your app', 'Passwordless service', 'Store', 'User’s inbox'], steps: [
      S(0, 'Issue a challenge', 'For a subject, a purpose (sign-in), a scope and a destination address.', 'app'),
      S(1, 'Create it', 'A magic link or email code bound to exactly those things.', 'lib'),
      S(2, 'Keep it', 'In memory for tests, or the PostgreSQL adapter over your pool.', 'lib'),
      S(0, 'Send the email', 'A separate step: you put the link in a message and send it through your sender.', 'app'),
      S(3, 'User clicks', 'The link (or code) comes back to your app.', 'ext'),
      S(1, 'Verify', 'Returns opaque verification evidence, or a typed reason it failed.', 'lib'),
      S(0, 'Unlock something', 'You decide what the evidence means: a session, a confirmed address, a step-up.', 'app')
    ], intro: 'Passwordless verification is a separate service from delivery. Your app connects the two explicitly, so you control what is sent, when, and what a successful check unlocks.',
      takeaway: 'Verification and delivery never call each other. That’s what lets you test each one alone and swap either side.',
      opts: [['Flow', 'mode', ['send', 'magic link']]] };
  }
  renderVals() {
    const st = this.state;
    const F = this.flow();
    const N = F.steps.length;
    const cur = Math.min(st.cur, N);
    const OWN = { app: ['your app', '#FDF0DC', '#6B3404'], lib: ['library', '#EEE7FD', '#3B1785'], ext: ['outside', '#EDEFF3', '#3B4452'] };
    const steps = F.steps.map((s, i) => ({
      op: i < cur ? 1 : 0.18,
      cells: F.actors.map((_, a) => (a === s.a ? { has: true, n: i + 1, title: s.title, text: s.text, owner: OWN[s.owner][0], obg: OWN[s.owner][1], ofg: OWN[s.owner][2],
        bg: i === cur - 1 ? '#FFFFFF' : '#FAF8F4', border: i === cur - 1 ? '#17162B' : '#E4E0D8' } : { has: false }))
    }));
    const activeActor = F.steps[cur - 1] ? F.steps[cur - 1].a : -1;
    const actors = F.actors.map((n, i) => ({ name: n, bg: i === activeActor ? '#3B1785' : '#F4EFFE', fg: i === activeActor ? '#FFFFFF' : '#3B1785', border: i === activeActor ? '#3B1785' : '#E3D8FB' }));
    const TABS = [['llm', 'LLM Wire'], ['relay', 'Relay'], ['hell', 'Hellhound'], ['mail', 'Correio']];
    const tabs = TABS.map((t) => ({ label: t[1], cls: st.tab === t[0] ? 'on' : '', pick: () => this.setState({ tab: t[0], cur: 1 }) }));
    const opts = F.opts.map((op) => ({ label: op[0], choices: op[2].map((v) => {
      const key = v === 'magic link' ? 'magic' : v;
      const curV = st.o[op[1]] === 'magic' ? 'magic' : st.o[op[1]];
      return { label: v, cls: curV === key ? 'on' : '', pick: () => this.setState({ o: Object.assign({}, st.o, { [op[1]]: key }) }) };
    }) }));
    const qs = [
      { q: 'In an LLM Wire tool loop, who keeps the conversation history?',
        o: ['LLM Wire, inside the prepared request', 'Your application', 'The model provider'], c: 1,
        e: 'LLM Wire is a wire library: one call in, one typed outcome out. History, storage, tool execution and retries all belong to the caller, or to Fabric if you want an agent runtime.' },
      { q: 'A Relay tool handler crashes on an odd edge case. What happens to the MCP server?',
        o: ['The whole server goes down', 'That call’s isolated worker fails and the server keeps serving other calls', 'Relay retries the handler until it works'], c: 1,
        e: 'Handlers run in isolated workers, the BEAM’s isolation from module 1 in practice. One bad call can’t take the runtime with it.' },
      { q: 'After a Hellhound sign-in succeeds, who sets the session cookie?',
        o: ['Hellhound', 'The identity provider', 'Your application'], c: 2,
        e: 'Hellhound hands you a checked identity and keeps the tokens. Accounts, cookies and permissions are always your application’s.' }
    ];
    return Object.assign({
      tabs, flowIntro: F.intro, opts, actors, actorCount: F.actors.length, steps, cur, total: N,
      atStart: cur <= 1, atEnd: cur >= N,
      prev: () => this.setState({ cur: Math.max(1, cur - 1) }), next: () => this.setState({ cur: Math.min(N, cur + 1) }), showAll: () => this.setState({ cur: N }),
      takeaway: F.takeaway
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
