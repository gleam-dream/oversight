# End a moderation card when the gated tool refuses a verdict

<a id="adr-0044"></a>

Recorded on 2026-11-25.

## Decision

In the moderation desk, a verdict that the gated tool refuses at release ends
the card for every moderator. The tool refused the verdict, not the person who
gave it. In one transaction the desk records the refused verdict
(`record_refusal`), reports the world event `release_refused` about the post
(`happened`), which the point declares as superseding, and removes the
moderator's claim. Every occurrence about the post that has released nothing
then expires as superseded by `release_refused`. The queues derive from the
occurrence's status, so the card is in nobody's queue, and no per-moderator
check decides who may open it.

The card's settlement is the existing unreleased settlement "release refused".
The follower makes the post hidden pending review and tells the author that the
post awaits review, as for any decision that released nothing. A post that no
longer exists has nothing to show, hide or notify about, so the follower changes
nothing for it; the record keeps the refused verdict and the expiry.

When the transaction fails, the desk process crashes still holding its claim.
The desk supervisor starts it again, and the new process opens the card again
and records the refusal of that showing. A committed refusal has ended the
card, so a refusal is recorded once per card.

## Rationale and consequences

Before this decision, the refusal changed no status: the card stayed waiting,
and each moderator in turn opened it and was refused. A check that skipped a
card refused for the same moderator stopped one moderator's loop and left every
other moderator to repeat it. A state of the card itself cannot disagree with
who sees it.

The gated tool's guard refuses only a post that no longer exists, so a refusal
means no verdict about the post can be released. Superseding every unreleased
occurrence about the post follows from that. A guard that later refuses for a
reason that may pass would need its own rule: under this decision such a card
also ends, and a new revision of the post is what asks moderators again.

The patient registration and payout desks keep the occurrence waiting after a
refused release; their guards refuse for reasons a later verdict can meet.
