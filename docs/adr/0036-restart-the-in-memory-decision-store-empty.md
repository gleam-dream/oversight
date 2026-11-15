# Restart the in-memory decision store empty and seed it again

<a id="adr-0036"></a>

Recorded on 2026-11-15.

## Decision

- `moderation_desk` keeps the decision record, the backlog and the platform's rows in the `decisions_otp` store, in the memory of the store's owner process.
- The root supervisor is rest-for-one. Its children start in this order:
  1. the store owner;
  2. the platform seeder;
  3. the operator's counter;
  4. the desk supervisor, one-for-one over one process per person on duty;
  5. the `decisions_otp` runtime.
- When the store owner exits, the root starts an empty store under the same name. Every later child restarts and takes a handle to the new store. The seeder publishes the first policy version and the platform's rows again when the store holds no policy.
- The runtime sets a job aside after 3 counted failures instead of the library's default of 20. A model that raises or misses its deadline is an application failure, which the runtime counts.

## Rationale and alternatives

- A restarted in-memory store cannot recover what the old process held. Restarting with the old handles would leave every later child failing against a store that no longer exists. Rest-for-one makes the dependency explicit.
- The desk starts before the runtime and neither uses the other, so a runtime restart leaves the desk running.
- A scripted classifier that raises fails the same way every time. Three attempts on the record show the retry without keeping the trigger in the backlog.
- A record that must outlive the VM uses `decisions_postgres`, as `clinic_registration` and `payout_desk` do. This application demonstrates the runtime without a database; it makes no durability claim.

## Consequences

- A store restart loses every occurrence, wake-up, settlement notice, trigger and platform row. A restart of the counter loses its counts. A desk process restart loses the card being read and its verdict transaction; its claim row survives in the store. A desk process whose subscriptions cannot be made fails its start, and the desk supervisor starts it again.
- A worker, the sweeper, the dispatcher or a desk process can be killed without losing a decision, because each acts on store rows and keeps none of its own. The supervision tests kill each of them and pass the library's invariant check.
