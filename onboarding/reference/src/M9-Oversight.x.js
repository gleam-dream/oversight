  extraState() { return { pv: 1 }; }
  cases400() {
    if (this._cases) return this._cases;
    const rng = GD.rng(21), out = [];
    for (let i = 0; i < 400; i++) {
      const ax = Math.pow(10, 1 + Math.pow(rng(), 1.6) * 2);
      const amount = Math.max(10, Math.min(1000, ax < 100 ? Math.round(ax) : Math.round(ax / 5) * 5));
      const cf = 100 - Math.pow(rng(), 1.8) * 50, conf = Math.max(50, Math.min(100, Math.round(cf)));
      const wrong = rng() * 100 > cf;
      out.push({ ax, cf, amount, conf, wrong, sampled: rng() < 0.1 });
    }
    return (this._cases = out);
  }
  extraVals() {
    const v = this.state.pv, C = this.cases400();
    const X = (a) => 60 + ((Math.log10(a) - 1) / 2) * 660, Y = (c) => 20 + ((100 - c) / 50) * 260;
    let auto = 0, ask = 0, two = 0, err = 0, wrong = 0, sampledWrong = 0;
    const dots = C.map((c) => {
      const pro = v >= 2 && c.amount <= 100 && c.conf >= 90, need2 = !pro && v >= 4 && c.amount >= 500;
      if (pro) auto++; else { ask++; if (need2) two++; }
      if (c.wrong) { wrong++; if (pro) { err++; if (c.sampled) sampledWrong++; } }
      return { x: X(c.ax).toFixed(1), y: Y(c.cf).toFixed(1), r: 4.5, fill: pro ? '#15803D' : need2 ? '#3B1785' : '#7C4DCC',
        stroke: c.wrong ? '#B42318' : '#FFFFFF', sw: c.wrong ? 2 : 1,
        title: '€' + c.amount + ' at ' + c.conf + '%' + (c.wrong ? ' · model wrong' : '') + (pro ? ' · proceeds alone' : ' · asks finance'),
        pick: () => {
          this.setState(Object.assign({ amount: c.amount, conf: c.conf, ver: v }, this.occ0(c.amount, c.conf)));
          const el = document.getElementById('refund-point'); if (el) el.scrollIntoView({ behavior: GD.motion() ? 'smooth' : 'auto', block: 'start' });
        } };
    });
    const minutes = (ask + two) * 2;
    const nets = v === 1 ? 'A person sees everything. Safe, and slow: nothing proceeds alone.'
      : v === 2 ? 'One in ten of the cases that proceed alone is sampled for review after the fact (' + sampledWrong + ' of the wrong ones would be caught that way).'
      : v === 3 ? 'Sampling, plus a 10-minute hold: everything that proceeds alone can still be withdrawn by finance before release.'
      : 'Sampling, the hold, and two approvals from €500 (left of the dashed line is under €500).';
    return {
      pvOpts: ['v1 · Always ask', 'v2 · Small and sure', 'v3 · Undo window', 'v4 · Two for big'].map((l, i) => ({ label: l, cls: v === i + 1 ? 'on' : '', pick: () => this.setState({ pv: i + 1 }) })),
      dots, zoneX: 60, zoneW: (X(100) - 60).toFixed(1), zoneH: (Y(90) - 20).toFixed(1), zoneOp: v >= 2 ? 0.9 : 0,
      x500: X(500).toFixed(1), line500: v >= 4 ? 0.8 : 0,
      pAuto: auto, pAutoPct: '(' + Math.round((auto / 4)) + '%)', pAsk: ask, pMinutes: minutes >= 60 ? (minutes / 60).toFixed(1) + ' hours' : minutes + ' minutes',
      pErr: err, pWrong: wrong, pErrBg: err ? '#FEF6F5' : '#FFFFFF', pNets: nets,
      pAria: 'Scatter plot of 400 recommendations by amount and confidence under policy version ' + v + ': ' + auto + ' proceed alone, ' + ask + ' ask finance'
    };
  }
  tourDefs() {
    const go = (label) => ($) => { const a = $().occActions.find((x) => x.label.indexOf(label) === 0); if (a) a.go(); };
    return {
      gate: { reset: () => this.setState({ small: 'allow', large: 'approval', del: 'deny', appr: {} }), steps: [
        { t: 'A support agent was asked to refund a €40 fee and a €650 charge and close an account. The model proposes four tool calls; your policy sees every one.' },
        { t: 'With this policy, the lookup and the €40 refund run, the €650 refund waits for a person, and closing the account is denied, with the model told why.', a: () => this.setState({ small: 'allow', large: 'approval', del: 'deny', appr: {} }) },
        { t: 'A person approves the €650 refund. Only then does it run, and the run can finish.', a: ($) => $().calls[2].approve() },
        { t: 'Now hand refunds over instead of running them. The run ends at once as HandedOver; the calls after it in the same reply are withdrawn.', a: ($) => $().rules[0].opts[2].pick() },
        { t: 'The model proposes; your policy decides. Rewrite the policy yourself.' }
      ] },
      plug: { reset: () => this.setState({ store: 'dir', inflight: true, killed: false }), steps: [
        { t: 'A run is halfway through a refund when the VM dies. What survives depends on where the store keeps its records.' },
        { t: 'In-memory store: kill the VM and the run is simply gone, along with any record of the refund in flight.', a: ($) => { $().stores[0].pick(); $().kill(); } },
        { t: 'Directory store: the record is on disk, and recover(run id) takes over. The in-flight refund is marked uncertain and blocks dependent work.', a: ($) => { $().stores[1].pick(); $().kill(); } },
        { t: 'PostgreSQL store: a leased store checks the old owner is gone before taking over. The production choice.', a: ($) => { $().stores[2].pick(); $().kill(); } },
        { t: 'Handles don’t own runs; the store does. Try the combinations yourself.' }
      ] },
      point: { reset: () => this.setState(Object.assign({ ver: 1, amount: 40, conf: 95, tool: 'release' }, this.occ0(40, 95))), steps: [
        { t: 'A billing model recommends refunding a €40 fee at 95% confidence. The decision point takes it from here.' },
        { t: 'Policy v1 asks finance for everything. The occurrence now waits, with a card showing exactly what the model saw.', a: go('Read policy') },
        { t: 'Bia approves. The refund is released to the gated tool, once, inside her verdict’s transaction.', a: go('Bia approves') },
        { t: 'Publish v3: small, confident refunds proceed alone, but are held for a 10-minute undo window first.', a: ($) => { $().versions[2].pick(); go('Read policy')($); } },
        { t: 'Finance spots a problem and withdraws it during the hold. Nothing is released, and the record says who stopped it.', a: go('Finance withdraws') },
        { t: 'v4 with a €600 refund: it takes two different people from finance. Every step lands in the append-only record.', a: () => { this.setState(Object.assign({ ver: 4, amount: 600, conf: 95 }, this.occ0(600, 95))); go('Read policy')(() => this.__vals()); } },
        { t: 'Climb or descend the ladder yourself, then scroll down to see four hundred cases at once.' }
      ] },
      p400: { reset: () => this.setState({ pv: 1 }), steps: [
        { t: 'Four hundred recommendations. Each dot is one refund; a red ring means the model was wrong about it.' },
        { t: 'v1: everything asks a person. Zero mistakes slip out, and finance spends hours clicking.', a: () => this.setState({ pv: 1 }) },
        { t: 'v2: the green zone (small and confident) proceeds alone. Most of the people-time disappears, and a few wrong ones slip through: that’s why one in ten is sampled.', a: () => this.setState({ pv: 2 }) },
        { t: 'v4: the hold gives a window to catch mistakes, and big refunds need two people.', a: () => this.setState({ pv: 4 }) },
        { t: 'Now go back down the ladder: click any dot to replay that exact refund in the playground above.' }
      ] }
    };
  }
