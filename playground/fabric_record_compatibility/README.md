# Fabric record reader compatibility

Checks that a previous public Fabric reader refuses a history-aware version 8 record before executing
its model. A writer completes a run through `fabric.start_with_input`, and a separate reader package
pinned to Fabric revision [`c92e97c`](https://github.com/gleam-dream/fabric/tree/c92e97ca3357c15dd26a2fcb59a77bedcffda539)
opens the directory record and requires `Error(fabric.UnsupportedVersion(8))`. Both consumers import
public Fabric modules only, and the old reader's model panics if called.

## Run

Supply the Fabric checkout being evaluated; it must contain the pinned reader commit, and its sibling
repositories must contain the commits recorded in `sibling-revisions.txt` at the reader commit. From the Oversight root:

```sh
mkdir -p .artifacts/history-tmp
TMPDIR="$PWD/.artifacts/history-tmp" nix develop -c python3 \
  playground/fabric_record_compatibility/check.py \
  "$PWD/../fabric"
```

The script builds the writer from that checkout, snapshots the old reader and its pinned dependencies
from local Git, and shares only a disposable directory store between separate processes. Success prints
`PASS new v8 record written through public facade` and `PASS c92e97c public reader rejects v8 without execution`.
Temporary sources, manifests and records are removed on exit.

The experiment establishes reader refusal, not mixed-version execution, PostgreSQL behavior or live-provider
compatibility. The [evidence design](../../docs/design/evidence/design.typ#experiments-and-acceptance-evidence)
states the limits, and the [oracle reference](../../docs/ORACLE.md) lists the pinned reader. This is the one
retained experiment outside `bash scripts/test-experiments.sh`, because it needs Git history that CI checkouts lack.
