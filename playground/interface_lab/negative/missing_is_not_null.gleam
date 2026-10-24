// THROWAWAY: Property absence and an explicit null require distinct constructors.
import lab/blueprint as b

pub fn invalid() {
  b.encode(b.object(b.optional("note", b.nullable(b.text()))), b.Null)
}
