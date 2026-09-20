# Blueprint number policy

## Status

- This note records the numeric direction selected from source inspection and host probes. The [standalone kernel](../playground/interface_lab/EXACT-NUMBERS.md) now has constructive consumer and independent oracle evidence. Integration into Value, schemas, and transports remains open.
- Erlang/OTP remains the first production target. The design preserves explicit representation limits so portable components cannot silently change a number when another runtime is used.

## Contract evidence

- JSON number syntax excludes NaN and Infinity. Implementations may bound accepted magnitude and precision; commonly used binary64 values approximate some decimal inputs. [RFC 8259, section 6](https://www.rfc-editor.org/rfc/rfc8259#section-6).
- JSON Schema adds no numeric precision bound. Its integer type accepts any number whose fractional part is zero, so decimal and exponent spellings can represent integers. [Validation sections 4.2 and 6.1.1](https://json-schema.org/draft/2020-12/json-schema-validation#section-4.2).
- The current laboratory has only `Value.Int` and a matching integer decoder. Extending the wire vocabulary without revisiting schema validation would leave spelling-dependent integer acceptance.

## Measured host behavior

- [Reproducible commands and raw output](blueprint-number-host-probes.txt) record Node 22.21.1 and OTP 28 / ERTS 16.2. These probes call the host JSON parsers directly.

| Input              | Node JSON.parse               | OTP json:decode |
| ------------------ | ----------------------------- | --------------- |
| `1.0`              | Number `1`                    | Float `1.0`     |
| `9007199254740993` | Rounded to `9007199254740992` | Exact integer   |
| `1e400`            | Infinity                      | Exception       |
| `1e-400`           | Zero                          | `0.0`           |

- Node JSON serialization emits `null` for Infinity and NaN. A post-parse finite check can detect Infinity but cannot recover a rounded integer or underflowed decimal.
- The [compatibility manifest](../playground/blueprint_compatibility/manifest.toml) pins `gleam_json` 3.1.0 and `gleam_stdlib` 1.0.5. Inspected JavaScript JSON FFI delegates to JSON.parse and JSON.stringify. Its source paths and hashes are recorded with the probe output.
- Inspected dynamic decoding distinguishes native integers from floats on Erlang; the JavaScript integer branch uses Number.isInteger and its float branch accepts JavaScript numbers. These source observations are not cross-target Gleam acceptance tests or claims about newer releases.

## Selected direction

- Use one opaque exact decimal-number leaf in the existing Value vocabulary. Do not introduce another general JSON algebra.
- Parse and retain a validated decimal representation before any machine-number conversion. Numeric comparison and integrality must not pass through Float.
- Keep syntax rejection, explicit resource limits, schema rejection, and unsupported native representation distinct. A valid JSON number that cannot fit a requested native type is not schema-invalid.
- Use checked native projections. Exact conversion means mathematical equality; rounded conversion requires a separately named opt-in operation.
- Preserve the existing Int and Float domain use cases through explicit projections. This direction does not make a machine Float the definition of JSON number semantics.

```gleam
pub opaque type JsonNumber

pub fn parse_number(NumberLimits, String) -> Result(JsonNumber, NumberError)
pub fn number_text(JsonNumber) -> String
pub fn compare(JsonNumber, JsonNumber) -> NumberOrder
pub fn is_integer(JsonNumber) -> Bool
pub fn from_int(Int) -> JsonNumber
pub fn to_int_exact(JsonNumber, IntegerProjectionLimit) -> Result(Int, IntegerProjectionError)
pub fn from_float_exact(Float) -> Result(JsonNumber, FloatConstructionError)
pub fn to_float_exact(JsonNumber) -> Result(Float, FloatProjectionError)
```

- The kernel consumer now exercises separate parse and integer-projection limits, positive canonical zero, compact scientific rendering, and distinct projection errors. These signatures summarize that prototype; they do not establish a promoted package API.
- Exact conversion of decimal `0.1` to binary64 fails; `0.5` succeeds. Converting an existing binary64 `0.1` to an exact decimal must preserve its full binary rational value, not emit the shortest roundtrip spelling.
- `from_int` preserves the native input it receives. It cannot reconstruct an integer already rounded before the call; JavaScript input policy remains explicit work.

## Integration obligations

- Native and runtime schemas share mathematical integer semantics and exact comparisons. Numeric schema bounds may themselves be fractional.
- Loading and rendering retain exact numeric bounds. Unsupported generated numeric types must fail explicitly rather than silently become Float.
- Relay and LLM reuse the same numeric leaf; a provider may declare narrower numeric restrictions. Generic schema admission does not prove transport precision.
- Published Blueprint 1.x adapters remain compatibility boundaries. Exact-number support does not imply historical decoder parity.
- The independent schema oracle must parse exact decimal inputs and distinguish schema validity from native representability. Its current Boolean decoder/validator agreement is insufficient for that distinction.

## Constructed boundary and next experiments

- The standalone consumer exercises equivalent forms, negative zero, large integers, exact projections, overflow, underflow, invalid grammar, and explicit resource rejection. Its 62-case oracle uses independent exact arithmetic and float-bit inspection.
- Compiler negatives reject JsonNumber as Float and parse limits as integer-projection limits. Native integer and float construction remain explicit operations.
- Integrate the leaf into Value, codecs, schema documents, validation, transport consumers, and generation through coherent follow-up waves. Byte parsing of complete JSON, numeric enums, multipleOf, all bound variants, and cross-target acceptance remain in scope.
