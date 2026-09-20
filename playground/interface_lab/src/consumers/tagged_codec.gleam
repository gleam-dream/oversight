// THROWAWAY: Typed alternatives carry different payloads through one tool.
import lab/blueprint as b
import lab/relay
import lab/value as v

pub type Decision {
  Approve(quantity: Int)
  Decline(reason: String)
}

pub fn decision_codec() -> b.Codec(Decision) {
  let assert Ok(quantity) = b.integer_between(1, 100)
  let assert Ok(codec) =
    b.tagged(
      "approve",
      b.field("quantity", quantity),
      "decline",
      b.field("reason", b.text()),
    )
  b.imap(
    codec,
    fn(choice) {
      case choice {
        b.Left(quantity) -> Approve(quantity)
        b.Right(reason) -> Decline(reason)
      }
    },
    fn(decision) {
      case decision {
        Approve(quantity) -> b.Left(quantity)
        Decline(reason) -> b.Right(reason)
      }
    },
  )
}

pub fn probe() -> Nil {
  let codec = decision_codec()
  let approved =
    v.Object([
      #("tag", v.Text("approve")),
      #("value", v.Object([#("quantity", v.Int(2))])),
    ])
  let declined =
    v.Object([
      #("value", v.Object([#("reason", v.Text("stock"))])),
      #("tag", v.Text("decline")),
    ])
  let assert Ok(Approve(2)) = b.decode(codec, approved)
  let assert Ok(Decline("stock")) = b.decode(codec, declined)
  let assert True = b.encode(codec, Approve(2)) == Ok(approved)
  let assert Ok(raw_decline) = b.encode(codec, Decline("stock"))
  let assert Ok(Decline("stock")) = b.decode(codec, raw_decline)
  let assert Error(b.EncodeAtField("value", b.EncodeAtField("quantity", _))) =
    b.encode(codec, Approve(0))
  let assert Error(b.DecodeAtField("value", b.DecodeAtField("quantity", _))) =
    b.decode(
      codec,
      v.Object([
        #("tag", v.Text("approve")),
        #("value", v.Object([#("quantity", v.Int(101))])),
      ]),
    )
  let assert Error(b.DecodeAtField("tag", _)) =
    b.decode(codec, v.Object([#("tag", v.Text("other")), #("value", v.Null)]))
  let assert Error(b.DecodeAtField("tag", _)) =
    b.decode(
      codec,
      v.Object([
        #("tag", v.Text("approve")),
        #("tag", v.Text("decline")),
        #("value", v.Null),
      ]),
    )
  let assert Error(b.DecodeAtField("extra", _)) =
    b.decode(
      codec,
      v.Object([
        #("tag", v.Text("approve")),
        #("value", v.Null),
        #("extra", v.Int(1)),
      ]),
    )
  let assert Error(b.DecodeAtField("value", _)) =
    b.decode(codec, v.Object([#("tag", v.Text("approve"))]))
  let assert Error(b.DuplicateTag("same")) =
    b.tagged("same", b.int(), "same", b.text())
  let assert Error(b.InvalidIntegerBounds(2, 1)) = b.integer_between(2, 1)
  let assert Ok(single) = b.integer_between(1, 1)
  let assert Ok(1) = b.decode(single, v.Int(1))
  let assert Error(_) = b.encode(single, 2)
  let arbitrary = b.new(fn(item: Int) { Ok(v.Int(item)) }, fn(_) { Ok(0) })
  let assert Ok(unknown) = b.tagged("known", b.int(), "unknown", arbitrary)
  let assert Error(b.UnknownSchema) = b.schema(unknown)
  let tool =
    relay.tool("decide", codec, b.bool(), b.text(), fn(decision) {
      case decision {
        Approve(_) -> Ok(True)
        Decline(_) -> Ok(False)
      }
    })
  let assert Ok(_) = relay.declaration(tool)
  let assert Ok(v.Bool(True)) = relay.invoke(tool, approved)
  let assert Ok(v.Bool(False)) = relay.invoke(tool, declined)
  Nil
}
