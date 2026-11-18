  tourDefs() {
    const L = (i) => ($) => $().layers[i].pick();
    return { stack: { reset: () => this.setState({ layer: 0 }), steps: [
      { t: 'The whole course on one screen: six layers, each leaning on the one below. Press Next or Play to climb from the bottom.' },
      { t: 'At the bottom, the BEAM: a virtual machine of tiny isolated processes that only talk by sending messages.', a: L(5) },
      { t: 'OTP adds proven patterns on top: actors hold state, supervisors restart what crashes.', a: L(4) },
      { t: 'Gleam adds types: errors become values, impossible states can’t be built, messages are checked by the compiler.', a: L(3) },
      { t: 'Three foundation libraries everything else uses: Sinal to observe, JSON Blueprint to shape data, HTTP Gun to reach the network.', a: L(2) },
      { t: 'The building blocks: models, tools, sign-in, mail, durable jobs, workflows, agents and human decisions.', a: L(1) },
      { t: 'And your application on top, owning every decision. Click any layer yourself, or start module 1.', a: L(0) }
    ] } };
  }
