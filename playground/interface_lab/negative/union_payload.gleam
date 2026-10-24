// THROWAWAY: Each alternative retains its own payload type.
import lab/blueprint as b

pub fn invalid() {
  let assert Ok(codec) = b.tagged("number", b.int(), "text", b.text())
  b.encode(codec, b.Left("wrong branch payload"))
}
