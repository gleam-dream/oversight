class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = Object.assign({ answers: {}, plug: 0 }, this.actor0(), this.tree0());
  }
  componentWillUnmount() { (this.timers || []).forEach((t) => clearTimeout(t)); }
  actor0() {
    return {
      mail: [
        { label: 'add Book €12', kind: 'send', op: ['add', 'Book', 12] },
        { label: 'add Mug €8', kind: 'send', op: ['add', 'Mug', 8] },
        { label: 'get total', kind: 'call', op: ['total'] },
        { label: 'remove Book', kind: 'send', op: ['remove', 'Book'] }
      ],
      items: [], version: 0, lastStep: 'Nothing handled yet. Press the button.',
      aev: [{ f: 0, t: 2, label: 'add Book' }, { f: 0, t: 2, label: 'add Mug' }, { f: 0, t: 2, label: 'get total (call)', color: 'pink' }, { f: 0, t: 2, label: 'remove Book' }]
    };
  }
  tree0() {
    const names = [['Database pool', 'Connections to PostgreSQL'], ['HTTP client', 'An HTTP Gun pool for outbound calls'], ['Job runtime', 'Grind queues and workers'], ['Web server', 'Accepts incoming requests']];
    return { strategy: 'one_for_one', windowCount: 0, rootDown: false, pidN: 210,
      kids: names.map((n, i) => ({ name: n[0], what: n[1], status: 'running', pid: 201 + i, restarts: 0 })),
      treeMsg: 'Everything is running.', tev: [] };
  }
  later(fn, ms) { this.timers = this.timers || []; this.timers.push(setTimeout(fn, ms)); }
  renderVals() {
    const st = this.state;
    // ---------- actor ----------
    const step = () => {
      if (!st.mail.length) return;
      const m = st.mail[0];
      let items = st.items.slice(), text, changed = true;
      if (m.op[0] === 'add') { items.push({ name: m.op[1], price: m.op[2] }); text = 'Added ' + m.op[1] + '. Nothing replied: it was a send.'; }
      else if (m.op[0] === 'remove') {
        const i = items.findIndex((x) => x.name === m.op[1]);
        if (i >= 0) { items.splice(i, 1); text = 'Removed ' + m.op[1] + '.'; } else { text = 'No ' + m.op[1] + ' in the cart, so nothing changed.'; changed = false; }
      } else { const t = items.reduce((a, b) => a + b.price, 0); text = 'Replied "€' + t + '" to the caller, who was waiting. State unchanged.'; changed = false; }
      const who = m.from === 'B' ? 1 : 0;
      const ae = [{ f: 2, kind: 'note', label: 'handles ' + m.label, color: 'blue' }].concat(m.kind === 'call' ? [{ f: 2, t: who, label: 'reply €' + st.items.reduce((a, b) => a + b.price, 0), color: 'green', dash: true }] : []);
      this.setState({ mail: st.mail.slice(1), items, version: st.version + (changed ? 1 : 0), lastStep: '"' + m.label + '" → ' + text, aev: (st.aev || []).concat(ae).slice(-9) });
    };
    const burst = () => this.setState({ mail: st.mail.concat([
      { label: 'add Pen €3', kind: 'send', op: ['add', 'Pen', 3], from: 'A' },
      { label: 'get total', kind: 'call', op: ['total'], from: 'B' }]), aev: (st.aev || []).concat([{ f: 0, t: 2, label: 'add Pen' }, { f: 1, t: 2, label: 'get total (call)', color: 'pink' }]).slice(-9), lastStep: 'Two requests arrived at the same instant. They simply queued up, one behind the other.' });
    const mailbox = st.mail.map((m, i) => ({ label: m.label, kind: m.kind, bg: i === 0 ? '#FFFFFF' : '#F6F4FF' }));
    const total = '€' + st.items.reduce((a, b) => a + b.price, 0);
    const items = st.items.map((x) => ({ name: x.name, price: '€' + x.price }));

    // ---------- supervision tree ----------
    const S = {
      one_for_one: ['One for one', 'Only the crashed child restarts. Use it when children are independent of each other.'],
      one_for_all: ['One for all', 'Every child restarts. Use it when the children only make sense together.'],
      rest_for_one: ['Rest for one', 'The crashed child and every child started after it restart. Use it when later children depend on earlier ones, like a web server that needs the database pool.']
    };
    const strategies = Object.keys(S).map((k) => ({ label: S[k][0], cls: st.strategy === k ? 'on' : '', pick: () => this.setState({ strategy: k }) }));
    const crash = (i) => () => {
      if (st.rootDown) return;
      const wc = st.windowCount + 1;
      const name = st.kids[i].name;
      if (wc > 3) {
        this.setState({ windowCount: wc, rootDown: true,
          kids: st.kids.map((k, j) => Object.assign({}, k, { status: j === i ? 'crashed' : 'stopped' })),
          tev: (st.tev || []).concat([{ f: i + 1, kind: 'crash', label: 'crash #4' }, { f: i + 1, t: 0, label: 'EXIT', color: 'red', dash: true }, { f: 0, kind: 'crash', label: 'too many restarts: gives up' }]).slice(-9),
          treeMsg: name + ' crashed a 4th time within 5 seconds. Restarting clearly isn’t helping, so the supervisor stops every child and crashes itself. Its parent decides what next; here the application stops. That’s escalation.' });
        return;
      }
      const affected = st.strategy === 'one_for_one' ? [i] : st.strategy === 'one_for_all' ? [0, 1, 2, 3] : [0, 1, 2, 3].filter((j) => j >= i);
      this.setState({ windowCount: wc,
        kids: st.kids.map((k, j) => Object.assign({}, k, { status: j === i ? 'crashed' : (affected.indexOf(j) >= 0 ? 'stopping' : k.status) })),
        treeMsg: name + ' crashed. The supervisor got the exit signal…',
        tev: (st.tev || []).concat([{ f: i + 1, kind: 'crash', label: 'crash' }, { f: i + 1, t: 0, label: 'EXIT', color: 'red', dash: true }]).concat(affected.filter((j) => j !== i).map((j) => ({ f: 0, t: j + 1, label: 'stop', color: 'amber' }))).slice(-9) });
      this.later(() => {
        let pid = this.state.pidN;
        const kids = this.state.kids.map((k, j) => (affected.indexOf(j) >= 0 ? Object.assign({}, k, { status: 'running', pid: ++pid, restarts: k.restarts + 1 }) : k));
        const names = affected.map((j) => st.kids[j].name);
        const tev = (this.state.tev || []).concat(affected.map((j) => ({ f: 0, t: j + 1, label: 'start', color: 'green' }))).slice(-9);
        this.setState({ kids, pidN: pid, tev, treeMsg: 'Restarted ' + names.join(', ') + ' from a clean state' + (names.length > 1 ? ', in their original start order.' : '. Its neighbours never noticed.') });
      }, 800);
    };
    const tone = { running: ['#E2F4E7', '#0E4D25', '#B9E2C4', '#FFFFFF'], crashed: ['#FDECEA', '#7A1A12', '#E9B8B2', '#FBF3F2'], stopping: ['#FDF0DC', '#6B3404', '#F3D9B1', '#FFFBF4'], stopped: ['#EDEFF3', '#3B4452', '#D5D9E0', '#F6F7F9'] };
    const lab = { running: 'running', crashed: 'crashed', stopping: 'restarting', stopped: 'stopped' };
    const words = ['first', 'second', 'third', 'fourth'];
    const kids = st.kids.map((k, i) => Object.assign({}, k, { order: i + 1, orderWord: words[i], status: lab[k.status],
      sbg: tone[k.status][0], sfg: tone[k.status][1], border: tone[k.status][2], bg: tone[k.status][3],
      cantCrash: st.rootDown || k.status !== 'running', crash: crash(i) }));

    // ---------- plug-ins ----------
    const P = [
      { lib: 'HTTP Gun', short: 'outbound HTTP', layer: 'Foundations', tint: '#DDF3F0', ink: '#0B4A45', brings: 'A client pool process that admits requests and leases connections, plus one short-lived body-owner process for every open response.', you: 'the client’s lifetime, its limits and which destinations it may reach.' },
      { lib: 'Sinal forwarder', short: 'telemetry off the hot path', layer: 'Foundations', tint: '#DDF3F0', ink: '#0B4A45', brings: 'An optional, bounded forwarder process. Observers of the event prefixes you route to it run there instead of inside the code that emitted the event.', you: 'which event prefixes to route, and whether to use a forwarder at all.' },
      { lib: 'Grind', short: 'background jobs', layer: 'Durable work', tint: '#FDF0DC', ink: '#6B3404', brings: 'A runtime supervisor with one coordinator per queue, a short-lived attempt process per job run, and a lease renewer on its own database connection.', you: 'the PostgreSQL pool, the queues and their concurrency, and who runs migrations.' },
      { lib: 'Saga', short: 'workflows', layer: 'Durable work', tint: '#FDF0DC', ink: '#6B3404', brings: 'One coordinator process per workflow run with bounded action workers. A local run is tied to its caller: if the caller exits, the run is cancelled.', you: 'storage for durable runs, and when to drive, resume or cancel them.' },
      { lib: 'Fabric store', short: 'agent runs', layer: 'Agents & oversight', tint: '#FCE7F3', ink: '#5E0B3A', brings: 'A store that keeps run records and supervises the runners doing the work. A handle only addresses a run; dropping it does not cancel anything.', you: 'the backend (memory, directory or PostgreSQL), model clients and policy.' },
      { lib: 'Hellhound', short: 'sign-in & tokens', layer: 'Outside world', tint: '#EEE7FD', ink: '#3B1785', brings: 'Supervised caches for identity-provider discovery and signing keys, with client handles that stay valid across restarts.', you: 'accounts, session cookies and every permission decision.' },
      { lib: 'Relay', short: 'MCP server', layer: 'Outside world', tint: '#EEE7FD', ink: '#3B1785', brings: 'A runtime actor per server that keeps protocol state in order, plus an isolated worker for each tool call so one bad handler can’t take the server down.', you: 'the HTTP listener or mount point, the token verifier and per-request context.' }
    ];
    const plugs = P.map((p, i) => Object.assign({}, p, { cls: '', bg: st.plug === i ? p.tint : '#FFFFFF', border: st.plug === i ? p.ink : '#E4E0D8', pick: () => this.setState({ plug: i }) }));

    const qs = [
      { q: 'Two web requests try to add an item to the same cart actor at exactly the same moment. What happens?',
        o: ['A race condition corrupts the cart', 'They queue in the mailbox and the actor handles one, then the other', 'One of them is rejected with an error'], c: 1,
        e: 'An actor handles one message at a time. Concurrency happens between actors, never inside one, so there’s nothing to lock.' },
      { q: 'Children start in this order: database pool, HTTP client, job runtime, web server. With rest-for-one, the HTTP client crashes. What restarts?',
        o: ['Only the HTTP client', 'The HTTP client, job runtime and web server', 'Everything, including the database pool'], c: 1,
        e: 'Rest-for-one restarts the crashed child and everything started after it, because later children may depend on it. The database pool came first, so it’s left alone.' },
      { q: 'Why do gleam-dream libraries hand you a "supervised" child instead of quietly starting their own processes?',
        o: ['Gleam forbids background processes', 'So your application owns lifetimes: start order, restarts and shutdown', 'Supervised processes run faster'], c: 1,
        e: 'Ownership of lifetimes stays with the application. You decide what starts first, what restarts together, and what shuts down cleanly. You’ll see this rule again in module 4.' }
    ];
    return Object.assign({
      mailbox, mailEmpty: !st.mail.length, step, burst, items, total, version: st.version, lastStep: st.lastStep,
      resetActor: () => this.setState(this.actor0()),
      strategies, stratName: S[st.strategy][0], stratDesc: S[st.strategy][1], stratShort: S[st.strategy][0].toLowerCase(),
      kids, windowCount: Math.min(st.windowCount, 3), treeMsg: st.treeMsg,
      rootStatus: st.rootDown ? 'gave up, escalated' : 'watching 4 children',
      rootBg: st.rootDown ? '#FDECEA' : '#DCD9FF', rootFg: st.rootDown ? '#7A1A12' : '#241F6B',
      wait: () => this.setState({ windowCount: 0, treeMsg: st.rootDown ? 'Time passed, but the supervisor already gave up. Press Reset to start the application again.' : 'Five quiet seconds passed. The restart window is clear again.' }),
      resetTree: () => this.setState(this.tree0()),
      plugs, plug: plugs[st.plug]
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
