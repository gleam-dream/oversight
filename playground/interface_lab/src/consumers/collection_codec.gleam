// THROWAWAY: Collections retain paths and explicit null has one representation.
import lab/blueprint as b
import lab/value as v

pub fn probe() -> Nil {
  let codec = b.field("scores", b.list(b.nullable(b.int())))
  let native = [b.NonNull(3), b.Null, b.NonNull(7)]
  let raw = v.Object([#("scores", v.Array([v.Int(3), v.Null, v.Int(7)]))])
  let assert True = Ok(raw) == b.encode(codec, native)
  let assert True = Ok(native) == b.decode(codec, raw)
  let assert Ok([]) = b.decode(b.list(b.int()), v.Array([]))
  let assert Error(b.DecodeAtField("scores", b.DecodeAtIndex(1, _))) =
    b.decode(codec, v.Object([#("scores", v.Array([v.Int(3), v.Text("bad")]))]))
  let assert Ok(b.FieldSchema(
    "scores",
    b.ListSchema(b.NullableSchema(b.IntSchema)),
  )) = b.schema(codec)
  let assert True =
    b.schema_value(b.ListSchema(b.NullableSchema(b.IntSchema)))
    == v.Object([
      #("type", v.Text("array")),
      #(
        "items",
        v.Object([
          #(
            "anyOf",
            v.Array([
              v.Object([#("type", v.Text("null"))]),
              v.Object([#("type", v.Text("integer"))]),
            ]),
          ),
        ]),
      ),
    ])
  let arbitrary =
    b.new(fn(_: Int) { Error(b.CannotEncode("sentinel")) }, fn(_) { Ok(0) })
  let assert Error(b.EncodeAtIndex(1, _)) =
    b.encode(b.list(b.nullable(arbitrary)), [b.Null, b.NonNull(3)])
  let assert Error(b.UnknownSchema) = b.schema(b.list(b.nullable(arbitrary)))
  // An inner codec that itself accepts null must not create two native nulls.
  let nested = b.nullable(b.nullable(b.int()))
  let assert Ok(b.Null) = b.decode(nested, v.Null)
  let assert Error(_) = b.encode(nested, b.NonNull(b.Null))
  Nil
}
