// THROWAWAY: Structural schema requirements with logical, typed locations.
import lab/blueprint as b

pub type Segment {
  Property(String)
  Element
  TupleIndex(Int)
  NonNullCase
  TaggedCase(String)
}

pub type Feature {
  TextValues
  StringEnumValues(List(String))
  IntegerValues
  BooleanValues
  ClosedObject
  OptionalProperty
  ArrayValues
  FixedTuple
  NullableValues
  TaggedAlternatives
  IntegerBounds(min: Int, max: Int)
}

pub type Requirement {
  Requirement(path: List(Segment), feature: Feature)
}

// This is an inventory, not a complete provider policy or a wire-schema parser.
pub fn requirements(schema: b.Schema) -> List(Requirement) {
  at(schema, [])
}

fn at(schema: b.Schema, path: List(Segment)) -> List(Requirement) {
  case schema {
    b.TextSchema -> [Requirement(path, TextValues)]
    b.StringEnumSchema(labels) -> [Requirement(path, StringEnumValues(labels))]
    b.IntSchema -> [Requirement(path, IntegerValues)]
    b.BoolSchema -> [Requirement(path, BooleanValues)]
    b.IntegerRangeSchema(min, max) -> [
      Requirement(path, IntegerValues),
      Requirement(path, IntegerBounds(min, max)),
    ]
    b.FieldSchema(name, inner) -> [
      Requirement(path, ClosedObject),
      ..at(inner, append(path, [Property(name)]))
    ]
    b.ObjectSchema(properties) -> [
      Requirement(path, ClosedObject),
      ..properties_at(properties, path)
    ]
    b.ListSchema(inner) -> [
      Requirement(path, ArrayValues),
      ..at(inner, append(path, [Element]))
    ]
    b.PairSchema(left, right) -> [
      Requirement(path, ArrayValues),
      Requirement(path, FixedTuple),
      ..append(
        at(left, append(path, [TupleIndex(0)])),
        at(right, append(path, [TupleIndex(1)])),
      )
    ]
    b.NullableSchema(inner) -> [
      Requirement(path, NullableValues),
      ..at(inner, append(path, [NonNullCase]))
    ]
    b.TaggedSchema(left_tag, left, right_tag, right) -> [
      Requirement(path, ClosedObject),
      Requirement(path, TaggedAlternatives),
      ..append(
        at(left, append(path, [TaggedCase(left_tag), Property("value")])),
        at(right, append(path, [TaggedCase(right_tag), Property("value")])),
      )
    ]
  }
}

fn properties_at(
  properties: List(b.PropertySchema),
  path: List(Segment),
) -> List(Requirement) {
  case properties {
    [] -> []
    [b.PropertySchema(name, required, schema), ..rest] -> {
      let location = append(path, [Property(name)])
      let own = case required {
        True -> at(schema, location)
        False -> [
          Requirement(location, OptionalProperty),
          ..at(schema, location)
        ]
      }
      append(own, properties_at(rest, path))
    }
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [first, ..rest] -> [first, ..append(rest, right)]
  }
}
