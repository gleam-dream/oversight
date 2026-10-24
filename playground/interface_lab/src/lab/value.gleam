// THROWAWAY: Can typed ecosystem operations share an explicit data boundary?
pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  Text(String)
  Array(List(Value))
  Object(List(#(String, Value)))
}
