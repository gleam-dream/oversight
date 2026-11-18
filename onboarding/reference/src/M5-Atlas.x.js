  tourDefs() {
    return { atlas: { reset: () => this.setState({ sel: 'fabric', need: 'all' }), steps: [
      { t: 'Twelve libraries and three tools, one row per layer. Lower rows are used by higher ones, never the other way round.' },
      { t: 'Sinal, at the bottom. The dashed tiles all use it: eight libraries emit Sinal events.', a: ($) => $().rows[0].tiles[0].pick() },
      { t: 'Fabric, near the top. The outlined tiles are what it builds on: HTTP Gun, JSON Blueprint, LLM Wire and Sinal.', a: ($) => $().rows[4].tiles[0].pick() },
      { t: 'Or start from the job. "Call an LLM" lights up LLM Wire, and everything else fades.', a: ($) => $().needs[4].pick() },
      { t: '"Let a person decide" leads to Decisions.', a: ($) => $().needs[11].pick() },
      { t: 'Find a package by the job it does and the layer it sits on. Explore freely.', a: ($) => $().needs[0].pick() }
    ] } };
  }
