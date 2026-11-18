class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = Object.assign({ answers: {}, face: 'decode', dcase: 0, part: 1, policy: 'default' }, this.sinal0());
  }
  sinal0() { return { route: 'inline', slow: false, queue: 0, delivered: 0, dropped: 0, blockedMs: 0, lastNote: 'Emit an event to see where the time goes.' }; }
  componentDidMount() {
    this.tick = setInterval(() => {
      const s = this.state;
      if (s.route === 'fwd' && s.queue > 0) {
        const d = s.slow ? Math.min(s.queue, 24) : s.queue;
        this.setState({ queue: s.queue - d, delivered: s.delivered + d });
      }
    }, 300);
  }
  componentWillUnmount() { clearInterval(this.tick); }
  renderVals() {
    const st = this.state;
    // ---------- Sinal ----------
    const emit = (n) => () => {
      const s = this.state;
      if (s.route === 'inline') {
        const add = n * (s.slow ? 50 : 0.02);
        const note = s.slow
          ? (n > 1 ? n.toLocaleString() + ' events × 50 ms = ' + Math.round(add / 1000) + ' seconds of request time spent inside the slow observer. Every request that emitted waited for it.' : 'The request waited 50 ms for the slow observer before emit returned. Multiply that by your traffic.')
          : 'Fast observers run inline before emit returns. That’s simplest and perfectly fine.';
        this.setState({ delivered: s.delivered + n, blockedMs: s.blockedMs + add, lastNote: note });
      } else {
        const free = 1024 - s.queue, acc = Math.min(n, free), drop = n - acc;
        const queue = s.slow ? s.queue + acc : 0;
        const delivered = s.slow ? s.delivered : s.delivered + acc;
        const note = drop ? 'Requests returned at once. The forwarder accepted ' + acc.toLocaleString() + ' events, dropped ' + drop.toLocaleString() + ' and counted each drop. No retry, no fallback: best effort by design. It drains at the observer’s pace in its own process.'
          : (s.slow ? 'Handed to the forwarder; the request carried on immediately. The slow observer now runs in the forwarder’s process.' : 'Handed off and delivered almost instantly. Nothing dropped.');
        this.setState({ queue, delivered, dropped: s.dropped + drop, blockedMs: s.blockedMs + n * 0.005, lastNote: note });
      }
    };
    const routes = [['inline', 'Inline (no route)'], ['fwd', 'Routed via forwarder']].map((r) => ({ label: r[1], cls: st.route === r[0] ? 'on' : '', pick: () => this.setState({ route: r[0] }) }));
    const fmt = (ms) => (ms < 1 ? '< 1 ms' : ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(1) + ' s');

    // ---------- Blueprint ----------
    const faces = [['encode', 'Encode'], ['decode', 'Decode'], ['schema', 'Schema']].map((f) => ({ label: f[1], cls: st.face === f[0] ? 'on' : '', pick: () => this.setState({ face: f[0] }) }));
    const C = [
      { label: 'Valid', json: '{ "name": "Ada",\n  "age": 36,\n  "role": "admin" }', ok: true, res: 'Ok(User("Ada", 36, None, Admin))', why: 'Every required field is present and allowed. Email is absent, so it decodes to None.' },
      { label: 'Missing name', json: '{ "age": 36,\n  "role": "admin" }', res: 'Error at $.name\nmissing required field', why: 'A required field is missing. The error carries the exact JSON path, so you can show it to a user or feed it back to a model.' },
      { label: 'Age 200', json: '{ "name": "Ada",\n  "age": 200,\n  "role": "admin" }', res: 'Error at $.age\nabove the maximum of 150', why: 'The bound lives in the codec, so it is enforced on decode and published in the schema the model saw.' },
      { label: 'Unknown role', json: '{ "name": "Ada",\n  "age": 36,\n  "role": "owner" }', res: 'Error at $.role\nnot one of admin, member', why: 'Enums decode only to the variants you listed. "owner" can never sneak into your program as a string.' },
      { label: 'Repeated key', json: '{ "name": "Ada",\n  "name": "Eve",\n  "age": 36,\n  "role": "admin" }', res: 'Rejected\nrepeated key "name"', why: 'When admitting untrusted text, repeated object keys are refused. Otherwise two systems could disagree about which "name" was meant.' },
      { label: '5 MB of JSON', json: '{ "name": "AAAAAAAA…\n  (5,242,880 bytes)', res: 'Rejected\nover the byte limit', why: 'Untrusted text is admitted with a configurable byte limit, checked before any parsing work happens.' }
    ];
    const cc = C[st.dcase];
    const cases = C.map((c, i) => ({ label: c.label, cls: 'btn sm' + (st.dcase === i ? ' on' : ''), pick: () => this.setState({ dcase: i }) }));

    // ---------- HTTP Gun ----------
    const PARTS = [
      { name: 'Your process', tiny: 'calls send, opens streams', long: 'The caller. It sends a request and gets back either a collected response or a stream. Only the process that opened a streamed body may read it, which makes ownership of the bytes unambiguous.' },
      { name: 'Client pool', tiny: 'admits & leases', long: 'One process per client. It admits each request against your limits and leases connection capacity. You start it linked to a caller or under your supervisor; many callers share it.' },
      { name: 'Body owner', tiny: 'one per response', long: 'A short-lived process per response that coordinates the exchange: buffering limits, deadlines, cancellation, trailers and closing. If a limit trips, you get a typed failure, not a stuck process.' },
      { name: 'Gun connections', tiny: 'the wire', long: 'Gun, a mature Erlang client, speaks HTTP/1.1 and HTTP/2 with verified TLS and optional client certificates. HTTP Gun keeps Gun’s untyped messages away from your code.' },
      { name: 'Recorder & Sinal', tiny: 'optional', long: 'A recorder can capture exchanges into cassettes (with common secrets redacted) for offline tests. Lifecycle events with request ids flow to Sinal observers.' }
    ];
    const parts = PARTS.map((p, i) => ({ n: '0' + (i + 1), name: p.name, tiny: p.tiny,
      bg: st.part === i ? '#163A8A' : '#E0E9FD', fg: st.part === i ? '#FFFFFF' : '#163A8A', border: st.part === i ? '#163A8A' : '#C9D7FA',
      pick: () => this.setState({ part: i }) }));
    const D = [
      { url: 'https://api.payments.example', resolves: 'public address', cls: 'public', tls: true },
      { url: 'http://api.payments.example', resolves: 'public address, plaintext', cls: 'public', tls: false },
      { url: 'http://127.0.0.1:4000', resolves: 'loopback', cls: 'loop', tls: false },
      { url: 'https://reports.internal', resolves: '10.0.4.7 (private network)', cls: 'private', tls: true },
      { url: 'https://cdn.example', resolves: '169.254.169.254 (cloud metadata)', cls: 'private', tls: true }
    ];
    const pol = st.policy;
    const dests = D.map((d) => {
      let ok, why;
      if (d.cls === 'public') {
        if (!d.tls && pol === 'tls') { ok = false; why = 'plaintext refused by RequireTls'; }
        else { ok = true; why = d.tls ? 'public and encrypted' : 'public; the default permits plaintext'; }
      } else if (d.cls === 'loop') {
        ok = pol === 'test'; why = ok ? 'the test policy opted into loopback' : 'loopback must be opted into explicitly';
      } else { ok = false; why = 'resolves outside the public internet'; }
      return { url: d.url, resolves: d.resolves, verdict: ok ? 'Admitted' : 'Refused', why, bg: ok ? '#F1FAF3' : '#FEF6F5', border: ok ? '#B9E2C4' : '#E9B8B2' };
    });
    const policies = [['default', 'Default'], ['tls', 'RequireTls'], ['test', 'Local tests']].map((p) => ({ label: p[1], cls: pol === p[0] ? 'on' : '', pick: () => this.setState({ policy: p[0] }) }));

    const qs = [
      { q: 'A slow logging observer is adding latency to every request. What’s the Sinal way to fix it?',
        o: ['Route that event prefix through a supervised forwarder', 'Delete the telemetry calls', 'Raise the request timeout'], c: 0,
        e: 'A forwarder takes observers off the hot path. The trade-off: it’s bounded and best effort, so under a flood it drops and counts events instead of slowing you down.' },
      { q: 'A model answers with "age": 200, and the codec says age is 0 to 150. What happens?',
        o: ['It’s decoded and clamped to 150', 'Decoding fails with an error at $.age', 'The schema is ignored at runtime'], c: 1,
        e: 'The codec is both the schema the model saw and the decoder that checks it. A violation is a typed error with a JSON path, never a silently wrong value.' },
      { q: 'Your agent lets a model choose which URLs to fetch. What in HTTP Gun protects your internal network?',
        o: ['Cassettes', 'Batch concurrency limits', 'Destination policy checked against resolved addresses'], c: 2,
        e: 'Checking the resolved address catches names that point at private ranges or cloud metadata. Pair it with an application policy on which hosts the model may pick.' }
    ];
    return Object.assign({
      routes, slow: st.slow, slowLabel: st.slow ? 'Remove the slow observer' : 'Attach a slow observer (50 ms)', slowCls: st.slow ? 'btn warn' : 'btn',
      toggleSlow: () => this.setState({ slow: !st.slow }), emitOne: emit(1), burst: emit(2000),
      resetSinal: () => this.setState(this.sinal0()),
      queue: st.queue.toLocaleString(), queuePct: Math.round((st.queue / 1024) * 100),
      fwdBg: st.route === 'fwd' ? '#EAF7F5' : '#FFFFFF', fwdBorder: st.route === 'fwd' ? '#0F766E' : '#E4E0D8', fwdOp: st.route === 'fwd' ? 1 : 0.45,
      fwdNote: st.route === 'fwd' ? 'observers run here' : 'bypassed: observers run in the producer',
      blocked: fmt(st.blockedMs), blockColor: st.blockedMs > 1000 ? '#B42318' : '#17162B',
      delivered: st.delivered.toLocaleString(), dropped: st.dropped.toLocaleString(), dropColor: st.dropped ? '#B45309' : '#17162B',
      sinalNote: st.lastNote,
      faces, faceEncode: st.face === 'encode', faceDecode: st.face === 'decode', faceSchema: st.face === 'schema',
      cases, caseJson: cc.json, caseResult: cc.res, caseWhy: cc.why, caseBg: cc.ok ? '#F1FAF3' : '#FEF6F5', caseBorder: cc.ok ? '#B9E2C4' : '#E9B8B2',
      parts, part: PARTS[st.part], policies, dests
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
