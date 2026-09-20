# Tagged alternatives and integer constraints

## Question

- Can a domain decision with different branch payloads retain native types, precise errors, and a supported schema through a tool boundary?

## Result

- `tagged` combines two payload codecs under distinct static tags. The closed wire object contains `tag` and `value`.
- `Either(left, right)` preserves each payload type. `imap` adapts that product of codecs to a domain sum.
- Duplicate tags are rejected during construction. Unknown tags, duplicate raw keys, extra keys, missing payloads, and invalid payloads are rejected during decoding.
- The derived schema contains disjoint literal tags and a `oneOf` union. Either unknown payload schema makes the whole codec schema unavailable.
- `integer_between` checks inclusive bounds during both encoding and decoding and emits matching minimum and maximum constraints. Reversed bounds fail construction.
- Relay accepts the object-shaped tagged schema and uses the same codec for actual invocation.

## Evidence and limits

- `tagged_codec` exercises approve/decline decisions, an integer quantity constraint, malformed inputs, typed error paths, both Relay invocations, and unknown-schema propagation.
- `union_payload` fails compilation when a branch receives the other branch's payload type.
- Nested binary unions intentionally create nested wire objects. A flat extensible variant registry has not been justified by a consumer.
- Integer encoding remains fallible because the native `Int` type does not enforce bounds.
- General predicate-based refinement is absent because an arbitrary predicate cannot automatically produce an equivalent schema.
- Schema agreement still needs an independent validator. This wave does not establish provider-specific schema support.
