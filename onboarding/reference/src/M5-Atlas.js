class Component extends DCLogic {
  constructor(props) { super(props); this.state = { answers: {}, sel: 'fabric', need: 'all' }; }
  renderVals() {
    const st = this.state;
    const GH = 'https://github.com/gleam-dream/';
    const LAY = {
      found: { name: 'Foundations', sub: 'observe & shape', band: '#EAF7F5', ink: '#0B4A45', tint: '#DDF3F0' },
      trans: { name: 'Transport', sub: 'reach the network', band: '#ECF1FD', ink: '#163A8A', tint: '#E0E9FD' },
      edge: { name: 'Outside world', sub: 'models, tools, people, mail', band: '#F4EFFE', ink: '#3B1785', tint: '#EEE7FD' },
      dur: { name: 'Durable work', sub: 'outlive a request', band: '#FEF6EA', ink: '#6B3404', tint: '#FDF0DC' },
      over: { name: 'Agents & oversight', sub: 'models act, people decide', band: '#FDF0F7', ink: '#5E0B3A', tint: '#FCE7F3' },
      insp: { name: 'Inspection', sub: 'see what happened', band: '#EEF8F1', ink: '#0E4D25', tint: '#E2F4E7' },
      tool: { name: 'Tooling', sub: 'build & learn', band: '#F2F3F6', ink: '#3B4452', tint: '#EDEFF3' }
    };
    const P = [
      { id: 'sinal', name: 'Sinal', layer: 'found', status: 'Hex 0.1', tiny: 'Typed telemetry events and spans', needs: ['observe'], deps: [],
        one: 'Typed events and observers on top of the BEAM’s shared :telemetry registry. Emit a fact once; observe it with typed handlers.',
        owns: ['Typed event definitions with field codecs', 'Attaching and detaching observers, scoped groups, spans', 'An optional bounded forwarder to keep slow observers off the hot path'],
        you: ['Exporters, metric aggregation and dashboards', 'Which events route through a forwarder', 'Never building event names from user input'],
        notFor: 'durable delivery, metric storage or distributed tracing. It reports facts; it doesn’t keep them.' },
      { id: 'blueprint', name: 'JSON Blueprint', layer: 'found', status: 'Hex 2.0', tiny: 'Codecs that also produce JSON Schema', needs: ['data', 'model', 'tools'], deps: [], repo: 'https://github.com/lostbean/json_blueprint',
        one: 'Describe a data shape once to encode, strictly decode, and publish a JSON Schema from the same definition. Validate runtime schemas you receive, too.',
        owns: ['Typed codecs for records, unions, enums and bounded numbers', 'Strict decoding with a JSON path for every error', 'Schema generation and runtime schema contracts'],
        you: ['HTTP, authorization and protocol policy', 'Extra structural limits on untrusted input'],
        notFor: 'simple serialization where gleam/json is enough.' },
      { id: 'http_gun', name: 'HTTP Gun', layer: 'trans', status: 'Hex 0.1', tiny: 'Pooled, bounded HTTP client', needs: ['http'], deps: ['sinal'],
        one: 'An HTTP client with a reusable connection pool, collected or streamed responses, explicit limits, offline cassettes and honest failure evidence.',
        owns: ['Connection pooling over HTTP/1.1 and HTTP/2, verified TLS', 'Destination policy checked against resolved addresses', 'Limits, deadlines, cancellation, NotSent / MaybeSent evidence', 'Recording and replaying cassettes for tests'],
        you: ['What a status or body means', 'Retries, authentication and protocol framing like SSE', 'The client’s lifetime in your supervision tree'],
        notFor: 'automatic retries, redirects, cookies or caching. It moves bytes and tells the truth about them.' },
      { id: 'llm_wire', name: 'LLM Wire', layer: 'edge', status: 'Hex 0.1', tiny: 'Typed, bounded calls to model providers', needs: ['model'], deps: ['blueprint', 'sinal', 'http_gun'],
        one: 'Typed, bounded model calls to OpenAI, Anthropic and Google: structured answers decoded into Gleam values, tool calls, streaming and classification.',
        owns: ['Provider adapters and request encoding', 'Structured output checked against each provider’s schema profile', 'Streaming progress, timeouts, retry advice'],
        you: ['The conversation loop and its history', 'Authorizing and running tool calls', 'Retries, budgets and durable recovery'],
        notFor: 'running an agent. It’s the wire; Fabric is the agent runtime.' },
      { id: 'relay', name: 'Relay', layer: 'edge', status: 'Hex 0.2', tiny: 'MCP server and client', needs: ['tools'], deps: ['blueprint', 'sinal', 'http_gun'],
        one: 'Expose typed Gleam operations as MCP tools, resources and prompts, or call another MCP server, over stdio or Streamable HTTP.',
        owns: ['The MCP protocol: discovery, calls, resources, prompts, notifications', 'One typed tool definition shared by server and client', 'Isolated handler workers, deadlines, cancellation'],
        you: ['Handlers and business policy', 'The token verifier and per-request context', 'Where the endpoint is mounted'],
        notFor: 'authorization decisions. It admits a bearer token through your verifier; you decide what that caller may do.' },
      { id: 'hellhound', name: 'Hellhound', layer: 'edge', status: 'Hex 0.2 · pre-production', tiny: 'OIDC sign-in, OAuth tokens, JWTs', needs: ['auth'], deps: ['sinal', 'http_gun'],
        one: 'Sign users in through an existing identity provider, get OAuth tokens for services, and validate JWT access tokens on your API.',
        owns: ['OIDC login with PKCE, provider discovery and signing keys', 'Token custody, near-expiry refresh, logout outcomes', 'JWT validation, signed assertions and credential exchange'],
        you: ['Accounts and session cookies', 'Permission checks', 'Where durable custody is stored'],
        notFor: 'being an identity provider itself. It talks to one. Production use needs independent security review.' },
      { id: 'correio', name: 'Correio', layer: 'edge', status: 'Hex 0.1', tiny: 'Transactional email and passwordless', needs: ['email', 'auth'], deps: [],
        one: 'Send transactional email through SMTP, Postmark or a test capture, and add magic-link or email-code verification. Delivery and verification stay separate.',
        owns: ['Validated messages and MIME rendering', 'Bounded SMTP with Accepted / NotSent / Rejected / OutcomeUnknown', 'Challenges bound to subject, purpose and destination'],
        you: ['Templates and wording', 'Accounts, sessions and what verification unlocks', 'Connecting a challenge to its email'],
        notFor: 'an outbox, bounce handling or inbound mail. Pair it with Grind when sending must be durable.' },
      { id: 'grind', name: 'Grind', layer: 'dur', status: 'Hex 0.1', tiny: 'Durable background jobs on PostgreSQL', needs: ['jobs'], deps: ['sinal'],
        one: 'Typed, durable background jobs on OTP and PostgreSQL. Submit in the same transaction as your own write; outcomes are stored rows.',
        owns: ['Queues, leases, retries, snoozes, uniqueness', 'Typed outcomes and stored contracts', 'Transactional admission and recovery of uncertain attempts'],
        you: ['The PostgreSQL pool and migrations owner', 'External effects inside handlers', 'Queue concurrency per node'],
        notFor: 'cron schedules, multi-step dependencies or cluster-wide rate limits.' },
      { id: 'saga', name: 'Saga', layer: 'dur', status: 'Hex 0.2', tiny: 'Typed workflows with compensation', needs: ['workflow'], deps: ['sinal'],
        one: 'Typed, source-written workflows of dependent steps: concurrency, retries, undo of completed steps, and checkpoints to resume after a crash.',
        owns: ['A typed dependency graph of steps', 'Concurrency limits, timeouts, retry and compensation policy', 'Evidence for uncertain effects and durable checkpoints'],
        you: ['Clients, stable operation ids and idempotency', 'Storage and job scheduling for durable runs', 'Deciding to drive, resume or cancel'],
        notFor: 'making remote effects transactional. It undoes what it knows succeeded and holds what it can’t prove.' },
      { id: 'fabric', name: 'Fabric', layer: 'over', status: 'Hex 0.3', tiny: 'Bounded LLM agents and durable graphs', needs: ['agent'], deps: ['http_gun', 'blueprint', 'llm_wire', 'sinal'],
        one: 'Runs bounded LLM agents with typed tools and an explicit policy gate, plus durable control graphs. Runs are recorded so they can be approved, inspected and recovered.',
        owns: ['The agent loop, turn and tool limits, budgets', 'The policy gate: allow, deny, approval or hand over', 'Run records, recovery, uncertain-effect blocking'],
        you: ['Models, domain tools and policy', 'Store backend and supervision', 'Credentials and context (never stored with runs)'],
        notFor: 'retrieval or vector search, token streaming to users, or distributed Erlang.' },
      { id: 'decisions', name: 'Decisions', layer: 'over', status: 'Git only · not on Hex yet', tiny: 'Decision points with release-once', needs: ['human'], deps: ['blueprint', 'sinal', 'grind'],
        one: 'A decision point: a model recommends, a versioned policy proceeds or asks a person, and the final output reaches a gated tool at most once. Everything is an append-only record.',
        owns: ['Occurrences as append-only entries', 'Policy as versioned data, approvals, holds and undo windows', 'Release at most once, inside your transaction', 'Learning: agreement and accuracy per recommender'],
        you: ['Transactions and the database pool', 'The gated tool and who holds which decision set', 'How a trigger becomes a recommendation'],
        notFor: 'calling a model, running an agent or delivering jobs. It composes with Fabric, LLM Wire and Grind for those.' },
      { id: 'retrace', name: 'Retrace', layer: 'insp', status: 'Hex 0.1 · experimental', tiny: 'Session recording and replay', needs: ['replay'], deps: [],
        one: 'Record selected state and messages from a Lustre app, deliver them durably, and reconstruct the session later in an inert replay frame.',
        owns: ['Typed recording, checkpoints and wire validation', 'Lustre capture, delivery and a replay viewer', 'A server library for admission, indexing and archiving'],
        you: ['Deciding what is safe to record', 'Routing, authentication and storage', 'Keeping the exact build of each recording'],
        notFor: 'screen recording. It records your app’s own typed events, not pixels.' },
      { id: 'nix', name: 'Gleam Nix', layer: 'tool', status: 'Nix flake', tiny: 'Per-package Nix builds', needs: [], deps: [], repo: GH + 'gleam-nix',
        one: 'Builds each Gleam dependency as its own Nix derivation from manifest.toml, so projects share compiled packages and app edits rebuild only the app.',
        owns: ['Per-package builds and reuse', 'Composing Rebar3 and Mix packages'], you: ['Your flake and Nixpkgs input'], notFor: 'resolving versions; Gleam still does that.' },
      { id: 'agenttools', name: 'Gleam Agent Tools', layer: 'tool', status: 'skills', tiny: 'Skills for AI coding agents', needs: [], deps: [], repo: GH + 'gleam-agent-tools',
        one: 'Agent skills for writing Gleam well, with an optional language-server bridge, installable for AI coding assistants.',
        owns: ['Curated skills with decision trees and red flags'], you: ['Your agent configuration'], notFor: 'runtime use; it’s for development.' },
      { id: 'oversight', name: 'Oversight', layer: 'tool', status: 'catalogue', tiny: 'Catalogue plus 14 runnable apps', needs: [], deps: [], repo: GH + 'oversight',
        one: 'The ecosystem’s front door: a catalogue of the libraries and runnable example applications that compose them, all with scripted services.',
        owns: ['Reference compositions and their tests'], you: ['Adapting them, not inheriting them'], notFor: 'a framework. Read it, copy what fits.' }
    ];
    const APPS = { sinal: ['checkout', 'webhooks', 'extractor', 'support desk', 'tool hub', 'secure MCP', 'SSO portal', 'research agent', 'clinic', 'payout desk', 'moderation desk'],
      blueprint: ['extractor', 'support desk', 'tool hub', 'secure MCP', 'research agent', 'clinic', 'payout desk', 'moderation desk'],
      http_gun: ['checkout', 'webhooks', 'extractor', 'support desk', 'tool hub', 'secure MCP', 'SSO portal', 'research agent', 'clinic'],
      llm_wire: ['extractor', 'support desk', 'tool hub', 'research agent', 'clinic'], relay: ['tool hub', 'secure MCP', 'payout desk'],
      hellhound: ['SSO portal', 'secure MCP', 'support desk', 'payout desk'], correio: ['email portal'],
      grind: ['checkout', 'financial recovery', 'webhooks', 'extractor', 'secure MCP', 'research agent', 'clinic', 'payout desk'],
      saga: ['checkout', 'financial recovery', 'support desk', 'research agent', 'payout desk'], fabric: ['support desk', 'tool hub', 'research agent', 'payout desk'],
      decisions: ['clinic', 'payout desk', 'moderation desk'], retrace: ['session replay'] };
    const NEEDS = [['all', 'Show everything'], ['observe', 'see inside my service'], ['data', 'describe data shapes'], ['http', 'call HTTP APIs'], ['model', 'call an LLM'], ['tools', 'expose or call tools (MCP)'], ['auth', 'sign people in'], ['email', 'send email'], ['jobs', 'run background jobs'], ['workflow', 'run multi-step workflows'], ['agent', 'run an agent'], ['human', 'let a person decide'], ['replay', 'replay user sessions']];
    const byId = {}; P.forEach((p) => (byId[p.id] = p));
    const sel = byId[st.sel];
    const usedBy = P.filter((p) => p.deps.indexOf(sel.id) >= 0).map((p) => p.id);
    const rows = ['found', 'trans', 'edge', 'dur', 'over', 'insp', 'tool'].map((L) => Object.assign({}, LAY[L], {
      tiles: P.filter((p) => p.layer === L).map((p) => {
        const isSel = p.id === sel.id, isDep = sel.deps.indexOf(p.id) >= 0, isUser = usedBy.indexOf(p.id) >= 0;
        const match = st.need === 'all' || p.needs.indexOf(st.need) >= 0;
        return { name: p.name, tiny: p.tiny, pick: () => this.setState({ sel: p.id }),
          rel: isSel ? 'selected' : isDep ? 'builds on' : isUser ? 'uses it' : '',
          bcolor: isSel ? '#17162B' : (isDep || isUser) ? LAY[sel.layer].ink : '#E4E0D8',
          bstyle: isUser && !isSel ? 'dashed' : 'solid',
          shadow: isSel ? '0 5px 0 #17162B' : 'none',
          op: match ? 1 : 0.35 };
      }) }));
    const needs = NEEDS.map((n) => ({ label: n[1], cls: 'btn sm' + (st.need === n[0] ? ' on' : ''), pick: () => {
      const first = P.find((p) => p.needs.indexOf(n[0]) >= 0);
      this.setState(first && n[0] !== 'all' ? { need: n[0], sel: first.id } : { need: n[0] });
    } }));
    const depNames = sel.deps.map((d) => byId[d].name);
    const apps = APPS[sel.id] || [];
    const selV = Object.assign({}, sel, { layerName: LAY[sel.layer].name, tint: LAY[sel.layer].tint, ink: LAY[sel.layer].ink,
      depNames, depNone: depNames.length ? '' : 'Nothing else in gleam-dream',
      apps, appsNone: apps.length ? '' : (sel.layer === 'tool' ? 'Used to build and run them' : 'None yet'),
      repo: sel.repo || (GH + sel.id) });
    const sinalCount = P.filter((p) => p.deps.indexOf('sinal') >= 0).length;

    const qs = [
      { q: 'You need to send a document to OpenAI and get back a typed Invoice value. Which packages do the work?',
        o: ['Fabric on its own', 'LLM Wire with a JSON Blueprint codec, over your HTTP Gun client', 'Relay'], c: 1,
        e: 'One structured call is exactly LLM Wire’s job; the codec describes the Invoice shape and generates the schema. That’s the extractor example app. Fabric only enters when you need an agent loop.' },
      { q: 'Which package sits underneath most of the others?',
        o: ['Sinal', 'Grind', 'Saga'], c: 0,
        e: 'Eight libraries emit Sinal events. That’s why one set of observers can see inside HTTP calls, jobs, workflows and agents.' },
      { q: 'An agent proposes refunds. A person must approve the risky ones, and you want a durable record of who decided what so autonomy can grow over time. What fits?',
        o: ['Fabric alone, with an approval policy', 'Fabric hands the call over to a Decisions decision point', 'A Grind job per refund'], c: 1,
        e: 'Fabric can wait for approval, but Decisions adds versioned policy, append-only records and per-recommender tallies, so you can raise autonomy by publishing data. That’s the payout desk example.' }
    ];
    return Object.assign({ needs, rows, sel: selV, sinalCount }, this.quizVals(qs));
  }
/*HELPERS*/
}
