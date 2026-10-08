# Fabric record reader compatibility

## Question and scope

- Does the previous public Fabric reader refuse a history-aware version 8 record
  before executing its model? The writer completes a run through
  `fabric.start_with_input`; a separate old-reader package opens its directory
  record and requires `Error(fabric.UnsupportedVersion(8))`.
- The old reader is Fabric revision
  [`c92e97ca3357c15dd26a2fcb59a77bedcffda539`](https://github.com/gleam-dream/fabric/tree/c92e97ca3357c15dd26a2fcb59a77bedcffda539),
  licensed Apache-2.0. Its local package dependencies use the exact revisions in
  that commit's `sibling-revisions.txt`; their licenses remain with the temporary
  source snapshots.
- Both consumers import public Fabric modules only. The old reader's model
  panics if called. This experiment establishes a reader refusal, not successful
  mixed-version execution, PostgreSQL behavior or live-provider compatibility.

## Reproduce

- Supply the Fabric checkout being evaluated. That repository must contain the
  pinned reader commit, and its sibling repositories must contain the commits
  recorded in the reader's `sibling-revisions.txt`.
- From the Oversight repository root, run:

```sh
mkdir -p .artifacts/history-tmp
TMPDIR="$PWD/.artifacts/history-tmp" nix develop -c python3 \
  playground/fabric_record_compatibility/check.py \
  "$PWD/../fabric"
```

- The script prints the evaluated writer revision and source status. It builds
  the writer from that checkout, snapshots the old reader and its pinned source
  dependencies from local Git, and generates two small consumer manifests.
- Separate processes share only a disposable directory store. Temporary sources,
  generated manifests, downloaded packages and execution records are removed on
  exit. The script does not modify either Fabric checkout or read credential
  files; dependency retrieval may contact Hex.
- Success prints both `PASS new v8 record written through public facade` and
  `PASS c92e97c public reader rejects v8 without execution`. A failed compilation
  or assertion exits nonzero.

## Retained evidence

- The two Gleam inputs preserve the original disposable experiment's assertions.
  Their directory path is relative so each reproduction owns its records.
- Fabric's own record/version suites separately cover supported old reads and
  representable older writes. This experiment does not substitute for those
  suites or for the owning package's design and compatibility policy.
