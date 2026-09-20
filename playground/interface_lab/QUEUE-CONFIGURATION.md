# Local queue configuration

## Question

- Can a host plan local processing capacity without creating another queue admission or attempt owner?
- Queue configuration reuses the existing storage-owner and queue-name route. Two storage owners may use the same queue name.

## Capacity boundary

- Local concurrency must be positive. An active count must be nonnegative.
- A paused processor proposes no new claims. A processor at or above its configured limit also proposes no new claims.
- Available capacity is the configured limit minus active work, clamped at zero.
- A dispatch plan advises how many claims a host may attempt. It neither issues claims nor reserves capacity.
- A configuration collection rejects duplicate full queue routes. It does not merge queues merely because their names match.

## Maintenance consumer

- One storage owner's processor can pause while an independent owner's identically named queue continues processing.
- Admission still uses the existing typed queue interface. Finishing an active attempt still uses the existing claim owner.
- Scaling below the current active count lets existing work drain. Resuming does not create capacity until the count falls below the limit.

## Remaining scope

- The host must obtain an accurate count for the processor whose capacity it plans. Immutable configuration and counts do not establish atomic capacity reservation.
- Cluster-wide limits, persisted management commands, notifier delivery, fairness, supervision, worker registration, and live pause/scale behavior remain open.
- This experiment introduces no new retry, admission, or acknowledgement policy.
