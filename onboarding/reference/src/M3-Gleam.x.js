  tourDefs() {
    return {
      types: { reset: () => this.setState({ status: 'refunded', rcpt: false, refund: true, variant: 1, disputed: false }), steps: [
        { t: 'The same order modelled two ways: a loose record of optional fields on the left, a custom type with one variant per state on the right.' },
        { t: 'Loose: status "paid" with a receipt and no refund. It makes sense, but only by luck. Nothing enforced it.', a: () => this.setState({ status: 'paid', rcpt: true, refund: false }) },
        { t: 'Now "refunded" with no receipt: refunded but never paid. The program accepts it happily. That’s a bug waiting for production.', a: () => this.setState({ status: 'refunded', rcpt: false, refund: true }) },
        { t: 'Typed: choose the Refunded variant. It must carry both a receipt and a refund, so the nonsense order simply can’t be built.', a: ($) => $().variants[2].pick() },
        { t: 'The business adds a Disputed state. Loose model: zero warnings. Custom type: three compile errors, one for every place that must handle it.', a: ($) => { if (!this.state.disputed) $().toggleDisp(); } },
        { t: 'Make the compiler your first reviewer. Now try building nonsense on each side yourself.' }
      ] },
      rail: { reset: ($) => $().clearFails(), steps: [
        { t: 'Five steps to place an order. Each one returns Ok(value) or Error(reason).' },
        { t: 'When every step succeeds, the value rides the happy track to the end: Ok(receipt).', a: ($) => $().clearFails() },
        { t: 'Make "Reserve stock" fail: Error(OutOfStock) switches to the error track, and steps 4 and 5 never run.', a: ($) => $().rail[2].toggle() },
        { t: 'Now the charge fails instead. Notice the stock is already reserved: undoing earlier steps is Saga’s job, in module 8.', a: ($) => { $().clearFails(); $().rail[3].toggle(); } },
        { t: 'Errors are values, and the function’s type lists them. Flip the steps yourself.' }
      ] },
      msgs: { reset: ($) => $().clearMsgs(), steps: [
        { t: 'The cart only understands CartMessage: AddItem, RemoveItem and GetTotal. Watch both mailboxes as we send.' },
        { t: 'Send AddItem(Pen). Both worlds accept and handle it.', a: ($) => $().msgBtns[0].send() },
        { t: 'Send ChargeCard(€20), a payment message, to the cart. Erlang accepts it and fails later at runtime. Gleam refuses to compile.', a: ($) => $().msgBtns[2].send() },
        { t: 'Even a plain "hello" is caught before the program ever runs.', a: ($) => $().msgBtns[3].send() },
        { t: 'Typed mailboxes turn mystery crashes into compile errors. Send whatever you like now.' }
      ] }
    };
  }
