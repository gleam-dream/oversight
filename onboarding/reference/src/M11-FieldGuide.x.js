  tourDefs() {
    return { retrace: { reset: () => this.setState({ strat: 'det', priv: true, pos: 6 }), steps: [
      { t: 'A recorded cart session, rebuilt from typed events. The slider is the recording’s timeline.', a: () => this.setState({ pos: 0 }) },
      { t: 'Three events in: the cart opened and two items were added. The frame shows exactly what the app showed then.', a: () => this.setState({ pos: 3 }) },
      { t: 'Event 4 came from outside: the coupon service’s answer. Deterministic replay feeds that recorded result back through the same update function.', a: () => this.setState({ pos: 4 }) },
      { t: 'Protected-observation replay instead adopts the observations the app recorded after each step. Both need the exact build that recorded them.', a: () => this.setState({ strat: 'prot' }) },
      { t: 'The email was classified private at capture, so it was never stored: no viewer setting can bring it back.', a: () => this.setState({ pos: 6, priv: true }) },
      { t: 'Only when your app marks it safe is it recorded at all. Privacy is decided before anything is stored. Scrub freely now.', a: () => this.setState({ priv: false }) }
    ] } };
  }
