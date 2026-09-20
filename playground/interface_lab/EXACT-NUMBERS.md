# Exact JSON number kernel

## Question

- Can one mathematical decimal representation preserve JSON numeric meaning while making lossy native projections explicit?
- This experiment implements the [selected number policy](../../research/blueprint-number-policy.md) as a standalone kernel before changing the shared Value algebra.

## Representation

- An opaque number retains sign, normalized coefficient digits, and a base-ten exponent. Zero has one mathematical representation.
- Canonical rendering uses compact scientific notation. Rendering never expands a large exponent into a long run of zeroes.
- Integer classification concerns the mathematical value. Decimal points and exponent syntax do not by themselves make a number fractional.
- Exact comparison does not first convert either operand to a machine float.

## Boundaries

- Parsing requires explicit limits for token bytes, raw significand digits, and normalized exponent magnitude. Invalid syntax and resource rejection remain distinct.
- Token length is checked first. Complete numeric grammar precedes the significand budget; bounded exponent accumulation follows it.
- The written exponent accumulator is bounded before arithmetic expansion, including for zero. Normalization is followed by a separate exponent check.
- Integer projection requires a separate positive output-digit limit. Fractional values and excessive expansion reject before constructing an arbitrary-size integer.
- Float construction preserves the exact mathematical value of the finite binary64 input. It does not substitute a shortest round-trip decimal spelling.
- Float projection rejects overflow, underflow, and inexact rounding separately. An exact decimal tenth therefore differs from the exact value of the binary64 float commonly printed as `0.1`.
- The Erlang helper is a native dependency of this prototype kernel. Its numeric boundary uses closed variants that match the Gleam declarations.

## Consumer and oracle evidence

- Exercise normalization, ordering, integer classification, resource boundaries, exact large integers, and checked float conversions through the public API.
- Compare emitted token strings against Python Decimal and Fraction independently of Gleam arithmetic.
- Decode returned float bits independently and compare their exact fractions. Include positive and negative zero, an exact half, a binary64 tenth, the smallest positive subnormal, and the largest finite float.
- Compiler negatives reject an exact decimal as a Float and parse limits as permission for integer expansion.
- The independent oracle checks 62 emitted cases, including native integer construction, negative values, mixed syntax/resource failures, and every projection failure category reached by the corpus.
- Review checks deliberately corrupt float bits, a large integer, integer classification, canonical magnitude, and a float's exact decimal spelling, then remove a required fixture. The oracle rejects all six corruptions.
- The coherent snapshot gate passes 58 isolated consumers, 86 intended compiler failures, 47 executable probe groups, and the existing independent schema, generation, and Relay checks.

## Remaining scope

- This kernel does not yet replace the laboratory Value number constructors, Blueprint numeric codecs, schema constraints, code generation, or transport parsing.
- JSON Schema validity and native projection acceptance remain separate future oracle outcomes.
- JavaScript behavior, whole-document parsing, duplicate keys, hostile-input runtime bounds, and published Blueprint migration remain open.
- Erlang rejects construction of some nonfinite terms; this experiment must not claim NaN or infinity execution evidence that the runtime cannot supply.
- The native helper is exercised on Erlang/OTP through actual float bit patterns. This does not establish another runtime target's numeric behavior.
