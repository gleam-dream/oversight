  extraVals() {
    const F = this.flow(), N = F.steps.length, cur = Math.min(this.state.cur, N);
    const COLOR = { app: 'amber', lib: 'pink', ext: 'ink' };
    const OWN = { app: ['your app', '#FDF0DC', '#6B3404'], lib: ['library', '#EEE7FD', '#3B1785'], ext: ['outside', '#EDEFF3', '#3B4452'] };
    const events = F.steps.map((s, i) => {
      const prev = i === 0 ? s.a : F.steps[i - 1].a;
      return prev === s.a ? { f: s.a, kind: 'note', label: s.title, color: COLOR[s.owner] } : { f: prev, t: s.a, label: s.title, color: COLOR[s.owner] };
    });
    const s = F.steps[cur - 1];
    return {
      flowChart: GD.msc({ id: 'f7', lanes: F.actors, events, upto: cur, laneGap: 190, row: 30, numbers: true, active: s ? s.a : null, aria: 'Sequence chart of the selected flow, step ' + cur + ' of ' + N }),
      curStep: { n: cur, title: s.title, text: s.text, owner: OWN[s.owner][0], obg: OWN[s.owner][1], ofg: OWN[s.owner][2] }
    };
  }
  tourDefs() {
    return { flows: { reset: () => this.setState({ tab: 'llm', cur: 1, o: { tool: 'yes', allow: 'yes', token: 'valid', result: 'ok', later: 'yes', mode: 'send', outcome: 'Accepted' } }), steps: [
      { t: 'Four libraries at the edge of your service. Each column is a participant, each arrow a message, time flows down. Colours show who owns the step: amber your app, violet the library.' },
      { t: 'LLM Wire. Your app builds a request; prepare validates and encodes it with no network at all; then one bounded call goes out through HTTP Gun.', a: ($) => { $().tabs[0].pick(); $().next(); $().next(); } },
      { t: 'The model asks for a tool. Watch the arrows return to your app: you authorize and run every tool, then call again. The loop is yours.', a: ($) => $().showAll() },
      { t: 'Relay without a valid token: the request is rejected at admission and never reaches a handler.', a: ($) => { $().tabs[1].pick(); $().opts[0].choices[1].pick(); $().showAll(); } },
      { t: 'Hellhound: sign-in goes through the identity provider, Hellhound checks everything, and your app sets its own session cookie.', a: ($) => { $().tabs[2].pick(); $().showAll(); } },
      { t: 'Correio: a send can end in four ways. OutcomeUnknown is module 4’s MaybeSent again: don’t assume either way.', a: ($) => { $().tabs[3].pick(); $().opts[1].choices[3].pick(); $().showAll(); } },
      { t: 'Step through any flow and flip the options to explore other paths.' }
    ] } };
  }
