class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = Object.assign({ answers: {}, small: 'allow', large: 'approval', del: 'deny', appr: {}, store: 'dir', inflight: true, killed: false,
      amount: 40, conf: 95, ver: 1, tool: 'release' }, this.occ0(40, 95));
  }
  occ0(amount, conf) {
    return { phase: 'recommended', approvals: 0, visited: ['recommended'],
      entries: ['recommend: refund €' + amount + ' · confidence ' + conf + '% · key msg-4471'] };
  }
  renderVals() {
    const st = this.state;
    // ---------------- Fabric gate ----------------
    const R = [
      ['Refunds up to €100', 'small', [['allow', 'Allow'], ['approval', 'Approval'], ['handover', 'Hand over']]],
      ['Refunds over €100', 'large', [['approval', 'Approval'], ['handover', 'Hand over'], ['deny', 'Deny']]],
      ['Closing an account', 'del', [['deny', 'Deny'], ['approval', 'Approval']]]
    ];
    const rules = R.map((r) => ({ label: r[0], opts: r[2].map((o) => ({ label: o[1], cls: st[r[1]] === o[0] ? 'on' : '', pick: () => this.setState({ [r[1]]: o[0], appr: {} }) })) }));
    const C = [
      { turn: 1, call: 'lookup_order(customer: "ana")', kind: 'read' },
      { turn: 2, call: 'refund_fee(amount: €40)', kind: 'small' },
      { turn: 2, call: 'refund_fee(amount: €650)', kind: 'large' },
      { turn: 2, call: 'close_account(customer: "ana")', kind: 'del' }
    ];
    const DT = { allow: ['Allow', '#E2F4E7', '#0E4D25'], deny: ['Deny', '#FDECEA', '#7A1A12'], approval: ['RequireApproval', '#FFF1C2', '#5C4300'], handover: ['HandOver', '#EEE7FD', '#3B1785'], withdrawn: ['—', '#EDEFF3', '#3B4452'] };
    let handedOver = false, waiting = false;
    const calls = C.map((c, i) => {
      const d = handedOver ? 'withdrawn' : (c.kind === 'read' ? 'allow' : st[c.kind]);
      let effect, isWaiting = false, bg = '#FFFFFF', border = '#E4E0D8';
      if (d === 'withdrawn') { effect = 'Withdrawn: it was part of the same model reply and hadn’t started (NotStarted).'; bg = '#F6F7F9'; }
      else if (d === 'allow') effect = c.kind === 'read' ? 'Ran. Read-only tools are always allowed here. The result goes back to the model.' : 'Ran. The tool executed and its result went back to the model.';
      else if (d === 'deny') effect = 'Not run. The model sees the reason ("closing accounts needs a human") and the run continues.';
      else if (d === 'handover') { handedOver = true; effect = 'Not run, ever. The run ends at once as HandedOver with this call’s action and arguments. Your app files it, for example to a decision point.'; border = '#3B1785'; }
      else {
        const a = st.appr[i];
        if (a === 'yes') effect = 'Approved, then ran.';
        else if (a === 'no') effect = 'Rejected. The model is told and the run continues.';
        else { effect = 'Waiting for a person. If only approvals remain, the run suspends as stored data: no process has to stay alive.'; isWaiting = true; waiting = true; border = '#E0B000'; }
      }
      return { turn: c.turn, call: c.call, decision: DT[d][0], dbg: DT[d][1], dfg: DT[d][2], effect, waiting: isWaiting, bg, border,
        approve: () => this.setState({ appr: Object.assign({}, st.appr, { [i]: 'yes' }) }), reject: () => this.setState({ appr: Object.assign({}, st.appr, { [i]: 'no' }) }) };
    });
    let runStatus, runWhy, runBg, runFg;
    if (handedOver) { runStatus = 'Finished: HandedOver'; runWhy = 'No approval is left hanging and the model takes no further turn. When the decision is recorded, a follow-on run can continue the conversation from it.'; runBg = '#EEE7FD'; runFg = '#3B1785'; }
    else if (waiting) { runStatus = 'Suspended: waiting for approval'; runWhy = 'The run is stored data until someone answers. Approve or reject the yellow rows.'; runBg = '#FFF1C2'; runFg = '#5C4300'; }
    else { runStatus = 'Finished: typed answer'; runWhy = 'The model wrote its final answer. Remember: a finished answer doesn’t prove every action succeeded. Check the run’s snapshot before calling it a business success.'; runBg = '#E2F4E7'; runFg = '#0E4D25'; }

    // ---------------- pull the plug ----------------
    const SB = { mem: ['In memory', 'Gone with the VM.', 'Nothing to reopen. As far as anyone can tell, the run never happened.'],
      dir: ['Directory', 'Kept on disk.', 'recover(run id) takes over, because the old runner is gone. (Survives a restart on one host, not a power cut.)'],
      pg: ['PostgreSQL', 'Kept in PostgreSQL.', 'A leased store checks the old owner is gone, then recover takes over. The production choice.'] };
    const stores = Object.keys(SB).map((k) => ({ label: SB[k][0], cls: st.store === k ? 'on' : '', pick: () => this.setState({ store: k, killed: false }) }));
    const k = st.killed;
    const unc = !k ? '—' : !st.inflight ? 'Nothing was in flight.' : st.store === 'mem' ? 'Unknown, and the record is gone too.' : 'Marked uncertain: blocks dependent work.';

    // ---------------- Decisions ----------------
    const V = [
      { name: 'v1 · Always ask', rule: 'Every refund asks someone in finance.' },
      { name: 'v2 · Small and sure', rule: '≤ €100 at ≥ 90% confidence proceeds alone; 1 in 10 of those sampled for review. Otherwise ask finance.' },
      { name: 'v3 · With an undo window', rule: 'Like v2, but what proceeds alone is held for 10 minutes; finance may withdraw it.' },
      { name: 'v4 · Two for big ones', rule: 'Like v3, and from €500 it takes two approvals from finance.' }
    ];
    const SAMPLE = [[20, 97], [35, 92], [80, 99], [60, 85], [15, 95], [120, 98], [45, 91], [300, 96], [25, 70], [90, 93], [55, 99], [700, 99], [10, 94], [40, 88], [75, 96], [150, 91], [30, 99], [95, 90], [65, 97], [520, 95]];
    const proceeds = (v, a, c) => v >= 2 && a <= 100 && c >= 90;
    const versions = V.map((v, i) => ({ name: v.name, rule: v.rule, auto: SAMPLE.filter((s) => proceeds(i + 1, s[0], s[1])).length,
      bg: st.ver === i + 1 ? '#5E0B3A' : '#FFFFFF', fg: st.ver === i + 1 ? '#FFFFFF' : '#17162B', border: st.ver === i + 1 ? '#5E0B3A' : '#E4E0D8',
      pick: () => this.setState(Object.assign({ ver: i + 1 }, this.occ0(st.amount, st.conf))) }));
    const A = st.amount, Cf = st.conf, ver = st.ver;
    const pro = proceeds(ver, A, Cf), hold = pro && ver >= 3, need = pro ? 0 : (ver >= 4 && A >= 500 ? 2 : 1);
    const add = (entries, phase, extra) => {
      const s = this.state;
      this.setState(Object.assign({ entries: s.entries.concat(entries), phase, visited: s.visited.concat(s.visited[s.visited.length - 1] === phase ? [] : [phase]) }, extra || {}));
    };
    const release = (from, pre) => () => {
      const t = this.state.tool, p0 = pre || [];
      if (t === 'release') add(p0.concat(['accepted → release check passed', 'released: refund sent to the gated tool, once, in this transaction']), 'released');
      else if (t === 'unsure') add(p0.concat(['release attempt: tool Unsure (lost connection) → verb fails with ToolUnsure; nothing recorded as refused, try again']), from, from === 'awaiting' ? { approvals: 0 } : null);
      else if (from === 'held') add(p0.concat(['hold ended → release check: Refuse (balance too low)', 'refused']), 'refused');
      else add(p0.concat(['verdict completed, but the tool refused → ToolRefused: transaction rolled back', 'record_refusal (second transaction): refused verdict kept on the record; occurrence still waits']), 'awaiting', { approvals: 0 });
    };
    let occTitle, occWhy, occActions = [];
    const B = (label, go, warn) => ({ label, go, cls: 'btn' + (warn ? ' warn' : '') });
    const ph = st.phase;
    if (ph === 'recommended') {
      occTitle = 'Recommended'; occWhy = 'The model recommended a €' + A + ' refund at ' + Cf + '% confidence. Admitted once under its trigger’s key: a duplicate delivery would land on this same occurrence.';
      occActions = [B('Read policy v' + ver, () => {
        if (pro) add(['policy v' + ver + ': proceed' + (ver >= 2 ? ' (≤ €100, ≥ 90%)' : '') + (hold ? ' with a 10-minute hold' : '')], hold ? 'held' : 'accepted');
        else add(['policy v' + ver + ': ask finance (' + need + ' approval' + (need > 1 ? 's' : '') + ' needed)'], 'awaiting');
      }), B('A newer message supersedes it', () => add(['superseded by a newer event → expired'], 'expired'), true)];
    } else if (ph === 'accepted') {
      occTitle = 'Accepted by policy'; occWhy = 'No person needed. Next comes the release check and the gated tool, inside your transaction.';
      occActions = [B('Release', release('accepted'))];
    } else if (ph === 'awaiting') {
      occTitle = 'Awaiting finance (' + st.approvals + ' of ' + need + ')'; occWhy = 'A card shows the approver exactly what the model saw. ' + (need > 1 ? 'Two different people must approve.' : 'One approval completes it.');
      const approve = (who) => () => {
        const n = this.state.approvals + 1;
        if (n >= need) release('awaiting', ['approve by ' + who + ' (' + n + '/' + need + ')'])();
        else add(['approve by ' + who + ' (' + n + '/' + need + ')'], 'awaiting', { approvals: n });
      };
      occActions = [B(st.approvals === 0 ? 'Bia approves' : 'Caio approves', approve(st.approvals === 0 ? 'Bia' : 'Caio')), B('Reject', () => add(['reject by Bia'], 'rejected'), true), B('Deadline passes', () => add(['deadline reached → expired'], 'expired'), true)];
    } else if (ph === 'held') {
      occTitle = 'Held: 10-minute undo window'; occWhy = 'The policy let it through alone, but it waits before release. Finance can still withdraw it.';
      occActions = [B('Hold ends', release('held')), B('Finance withdraws in time', () => add(['withdrawn by Dani during the hold'], 'withdrawn'), true)];
    } else {
      const T = { released: ['Released, exactly once', 'The gated tool accepted the released refund. Nothing else in the system can refund this fee.'], rejected: ['Rejected', 'A person said no. The tool never ran, and the record says who decided, on what information.'], expired: ['Expired', 'Superseded or out of time. Nothing was released.'], withdrawn: ['Withdrawn', 'Taken back during the undo window. Nothing was released.'], refused: ['Refused', 'The hold ended but the release check refused. On the record, nothing released.'] }[ph];
      occTitle = T[0]; occWhy = T[1] + ' Every step is in the record: that’s what tallies agreement per model version later.';
      occActions = [B('Start a new occurrence', () => this.setState(this.occ0(A, Cf)))];
    }
    const PC = { recommended: '#EEE7FD', awaiting: '#FFF1C2', accepted: '#E0E9FD', held: '#FFF1C2', released: '#E2F4E7', rejected: '#FDECEA', expired: '#EDEFF3', withdrawn: '#EDEFF3', refused: '#FDECEA' };
    const path = st.visited.map((v, i) => ({ name: v, bg: i === st.visited.length - 1 ? '#17162B' : PC[v], fg: i === st.visited.length - 1 ? '#FFFFFF' : '#17162B', arrow: i < st.visited.length - 1 ? '→' : '' }));
    const terminal = ['released', 'rejected', 'expired', 'withdrawn', 'refused'].indexOf(ph) >= 0;
    const toolOpts = [['release', 'allows'], ['refuse', 'refuses'], ['unsure', 'is unsure']];
    const val = (e) => Number(e && e.target ? e.target.value : e);

    const qs = [
      { q: 'A Fabric policy answers HandOver for a refund call. What happens?',
        o: ['The tool runs later, once someone approves', 'The run ends as HandedOver: the tool never runs, and your app files the call, for example to a decision point', 'The model is asked to try a different tool'], c: 1,
        e: 'HandOver means "this isn’t this run’s to do". Nothing waits inside Fabric. Another system decides, possibly days later, and a follow-on run can continue from the decision.' },
      { q: 'You want a decision point to auto-approve more cases. How?',
        o: ['Change the code and deploy', 'Publish a new policy version: it’s data', 'Lower the model’s temperature'], c: 1,
        e: 'Policy is versioned data, read inside your transaction. Climbing or descending the autonomy ladder is a write, backed by the record of how often people agreed.' },
      { q: 'The same refund trigger message is delivered twice. What does Decisions do?',
        o: ['Creates two occurrences and refunds twice', 'Keeps one occurrence, because the trigger’s id is its key', 'Fails the second delivery with an error'], c: 1,
        e: 'Recommendations are admitted at most once per key, and the gated tool accepts a released output at most once. Duplicates are boring, which is the point.' }
    ];
    return Object.assign({
      rules, calls, runStatus, runWhy, runBg, runFg, resetGate: () => this.setState({ appr: {} }),
      stores, inflightLabel: st.inflight ? 'A refund call is in flight' : 'No tool call in flight', inflightCls: st.inflight ? 'btn warn' : 'btn',
      toggleInflight: () => this.setState({ inflight: !st.inflight, killed: false }), kill: () => this.setState({ killed: true }),
      recSurvives: k ? SB[st.store][1] : '—', afterRestart: k ? (st.store === 'mem' ? 'Nothing to recover.' : 'Recoverable by run id.') : '—',
      uncertain: unc, uncBg: k && st.inflight ? (st.store === 'mem' ? '#FDECEA' : '#FFF1C2') : '#FFFFFF',
      killWhy: !k ? 'Choose a backend, then kill the VM.' : SB[st.store][2] + (st.inflight && st.store !== 'mem' ? ' The in-flight refund may have reached the payment provider without a saved result, so Fabric won’t guess: it blocks whatever depends on it until you reconcile. You can declare a tool safe to replay only when repeating it is harmless.' : (st.inflight ? ' Reconcile by hand with the payment provider.' : '')),
      amount: A, conf: Cf, setAmount: (e) => this.setState(Object.assign({ amount: val(e) }, this.occ0(val(e), st.conf))), setConf: (e) => this.setState(Object.assign({ conf: val(e) }, this.occ0(st.amount, val(e)))),
      versions, path, occTitle, occWhy, occActions: occActions.concat(terminal ? [] : toolOpts.map((t) => ({ label: 'Gated tool ' + t[1], cls: 'btn sm' + (st.tool === t[0] ? ' on' : ''), go: () => this.setState({ tool: t[0] }) }))),
      entries: st.entries.slice().reverse(), occBg: terminal ? (ph === 'released' ? '#E2F4E7' : '#F6F7F9') : '#FFF7FC',
      resetOcc: () => this.setState(this.occ0(A, Cf))
    }, this.quizVals(qs));
  }
/*HELPERS*/
}
