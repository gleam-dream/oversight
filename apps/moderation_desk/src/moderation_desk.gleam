//// Moderation at volume on the BEAM with no database. `gleam run` starts
//// the application, moderates a scripted corpus under policy version 1,
//// replays the moderators' decisions to gate version 2, moderates 10 000
//// posts under version 2 with faults and duplicate deliveries, then shows
//// escalation, expiry, an edit, an appeal and a stale card, and prints
//// the operator's numbers and the invariant check.

import decisions
import decisions/occurrence
import decisions/store as port
import decisions/testing
import decisions/vocabulary.{type Verdict, Approve, Correct, Reason, Reject}
import decisions_otp/store
import gleam/erlang/process.{type Name}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration
import moderation_desk/app.{type App}
import moderation_desk/desk
import moderation_desk/domain
import moderation_desk/gate
import moderation_desk/intake
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/telemetry
import moderation_desk/wiring

/// How many posts step 3 moderates: the library's own
/// benchmark load.
pub const volume = 10_000

pub fn main() -> Nil {
  app.quiet()
  let assert Ok(a) = app.start(app.config())
  io.println("Moderation desk, in-memory store, no database")
  io.println("machine: " <> app.machine())
  io.println("")
  ladder(a)
  at_volume(a)
  time_passes(a)
  edits_and_appeals(a)
  stale_card(a)
  report(a)
  app.stop(a)
}

fn say(line: String) -> Nil {
  io.println("  " <> line)
}

fn count(n: Int) -> String {
  int.to_string(n)
}

fn person(a: App, name: String) -> Name(desk.Message) {
  let assert Ok(found) = app.person_named(a, name)
  found
}

/// Steps 1 and 2: version 1, then the gate.
fn ladder(a: App) -> Nil {
  io.println("1. Policy version 1: the rule model settles the obvious posts,")
  io.println("   moderators decide everything else")
  let posts = scripted.posts(1, 600)
  list.each(posts, fn(post) {
    let assert Ok(_) = app.receive(a, post)
  })
  let assert True =
    app.wait_until(fn() { app.all_settled(a, posts) }, within: 60_000)
  let numbers = app.numbers(a)
  say(
    count(numbers.by_rules)
    <> " settled by rules, "
    <> count(numbers.approved + numbers.corrected)
    <> " decided by moderators ("
    <> count(numbers.corrected)
    <> " corrected)",
  )
  io.println("2. The gate: replay the moderators' decisions before version 2")
  let s = app.store_of(a)
  let threshold = gate.Threshold(agreement_per_cent: 98, at_least: 50)
  let across = app.schedulers()
  let eager = gate.Candidate("eager classifier", "eager", point.version_2())
  let assert Ok(gate.Held(report)) =
    gate.publish_if_clear(s, app.desk_of(a), eager, threshold, across:)
  say("candidate \"eager\": held. " <> gate.describe(report))
  let careful = gate.Candidate("classifier 2", "2", point.version_2())
  let assert Ok(gate.Published(report)) =
    gate.publish_if_clear(s, app.desk_of(a), careful, threshold, across:)
  say("candidate \"2\": published. " <> gate.describe(report))
  say(
    count(report.examples)
    <> " examples replayed on "
    <> count(report.across)
    <> " processes; "
    <> count(report.drifted)
    <> " read an author history that has changed since (drift)",
  )
  io.println("")
}

/// Step 3: 10 000 posts under version 2.
fn at_volume(a: App) -> Nil {
  io.println(
    "3. Version 2 at volume: "
    <> count(volume)
    <> " posts, 1 in 100 delivered twice, 1 in 1000 hangs once, 3 always raise",
  )
  let before = app.numbers(a)
  let posts =
    scripted.posts(1001, 1000 + volume)
    |> list.map(fn(post) {
      let n = number(post)
      case n % 1000, n % 3333 {
        550, _ -> scripted.faulty(post, "[hang-once]")
        _, 0 -> scripted.faulty(post, "[raise]")
        _, _ -> post
      }
    })
  let started = app.monotonic_us()
  list.each(posts, fn(post) {
    let assert Ok(_) = app.receive(a, post)
    case number(post) % 100 {
      0 -> {
        let assert Ok(intake.Duplicate) = app.receive(a, post)
        Nil
      }
      _ -> Nil
    }
  })
  let healthy =
    list.filter(posts, fn(post) { !string.contains(post.text, "[raise]") })
  let assert True =
    app.wait_until(fn() { app.all_settled(a, healthy) }, within: 300_000)
  let us = app.monotonic_us() - started
  let after = app.numbers(a)
  say(
    count(volume)
    <> " posts settled in "
    <> seconds(us)
    <> " ("
    <> count(volume * 1_000_000 / int.max(us, 1))
    <> " posts/s), with "
    <> count(app.schedulers())
    <> " schedulers, 8 workers, 2 moderators, 1 senior, 1 reviewer",
  )
  say(
    "proceeded "
    <> count(after.proceeded - before.proceeded)
    <> ", waited for a person "
    <> count(after.waited - before.waited)
    <> ", sampled for review "
    <> count(after.sampled - before.sampled)
    <> ", duplicates refused "
    <> count(after.duplicates - before.duplicates),
  )
  say(
    "deadlines hit "
    <> count(after.deadlines - before.deadlines)
    <> ", classifier raised "
    <> count(after.raised - before.raised)
    <> ", triggers set aside "
    <> count(after.set_aside - before.set_aside),
  )
  // Sampling is a function of each id, uniform over sequential keys: about
  // 2 % of what version 2 let through on the classifier's answer waits for
  // a review. The rule model's answers proceed unsampled.
  let proceeded =
    after.proceeded - before.proceeded - { after.by_rules - before.by_rules }
  let sampled = after.sampled - before.sampled
  let per_mille = sampled * 1000 / int.max(proceeded, 1)
  let assert True = per_mille >= 15 && per_mille <= 25
  say(
    "sampled "
    <> count(sampled)
    <> " of "
    <> count(proceeded)
    <> " proceeded on the classifier's answer: "
    <> count(per_mille / 10)
    <> "."
    <> count(per_mille % 10)
    <> " %, within the 1.5 % to 2.5 % this run requires",
  )
  say("these are one run on this machine, not a guarantee")
  io.println("")
}

fn number(post: domain.Post) -> Int {
  string.replace(post.id, "post-", "") |> int.parse |> result.unwrap(0)
}

fn seconds(us: Int) -> String {
  float.to_string(int.to_float(us / 10_000) /. 100.0) <> " s"
}

/// Step 4: nobody is on duty while time passes.
fn time_passes(a: App) -> Nil {
  io.println(
    "4. Nobody is on duty: escalation after 30 minutes, expiry after 2 hours",
  )
  list.each(["ana", "bruno", "carla"], fn(name) {
    desk.on_duty(person(a, name), False)
  })
  let s = app.store_of(a)
  let posts = [
    scripted.post(20_090),
    scripted.post(20_190),
    scripted.post(20_290),
  ]
  list.each(posts, fn(post) {
    let assert Ok(_) = app.receive(a, post)
  })
  let handle = store.handle(s)
  let assert True =
    app.wait_until(
      fn() {
        list.all(posts, fn(post) {
          awaiting(handle, post) == [point.moderators]
        })
      },
      within: 10_000,
    )
  say("3 insults wait for moderators")
  // Pause the runtime while the time passes: nothing is delivered.
  let assert Ok(Nil) = app.pause_runtime(a)
  store.advance(s, duration.minutes(31))
  process.sleep(100)
  let assert True =
    list.all(posts, fn(post) { awaiting(handle, post) == [point.moderators] })
  // Stop the runtime's whole tree; the root starts it again over the same
  // store. The escalations are rows, so they are still due.
  let assert Ok(Nil) = app.restart_runtime(a)
  let assert True =
    app.wait_until(
      fn() {
        list.all(posts, fn(post) { awaiting(handle, post) == [point.seniors] })
      },
      within: 10_000,
    )
  say(
    "31 minutes later nothing moved while the runtime was paused; stopped and started again, it escalated them to seniors",
  )
  store.advance(s, duration.minutes(90))
  let assert True =
    app.wait_until(
      fn() {
        list.all(posts, fn(post) {
          wiring.visibility(handle, post.id)
          == Ok(domain.HiddenPendingReview(domain.NobodyDecided))
        })
      },
      within: 10_000,
    )
  say("2 hours after arrival they expired: hidden pending review, authors told")
  io.println("")
}

fn awaiting(handle: store.Tx, post: domain.Post) -> List(String) {
  store.heads(handle)
  |> list.key_find(wiring.key(post))
  |> result.map(fn(head: port.Head) { head.awaiting })
  |> result.unwrap([])
}

/// Step 5: an edit supersedes, an appeal assesses.
fn edits_and_appeals(a: App) -> Nil {
  io.println("5. An edit and an appeal")
  let s = app.store_of(a)
  let handle = store.handle(s)
  let insult = scripted.post(20_391)
  let assert Ok(_) = app.receive(a, insult)
  let assert True =
    app.wait_until(fn() { awaiting(handle, insult) != [] }, within: 10_000)
  let assert Ok(edited) =
    intake.edit(
      s,
      app.desk_of(a),
      insult.id,
      "I tried the new release and the search is faster, sorry",
    )
  say(
    "the author edited a waiting post: "
    <> count(edited.superseded)
    <> " recommendation superseded",
  )
  let assert True =
    app.wait_until(
      fn() { wiring.visibility(handle, insult.id) == Ok(domain.Published) },
      within: 10_000,
    )
  say("the new revision proceeded under version 2 and is published")
  list.each(["ana", "bruno", "carla"], fn(name) {
    desk.on_duty(person(a, name), True)
  })
  // An insult hidden by moderators in step 3, appealed and upheld.
  let appealed = "post-1088"
  let assert Ok(domain.Hidden(_)) = wiring.visibility(handle, appealed)
  let assert Ok(Nil) = intake.appeal(s, app.desk_of(a), appealed, intake.Upheld)
  let assert Ok(post) = wiring.post(handle, appealed)
  let assert Ok(known) =
    decisions.read(app.desk_of(a), handle, occurrence: wiring.key(post))
  say(
    "an appeal on "
    <> appealed
    <> " was upheld: "
    <> count(list.length(occurrence.assessments(known)))
    <> " assessment on the record, the post is "
    <> visibility_name(wiring.visibility(handle, appealed)),
  )
  io.println("")
}

fn verdict_name(verdict: Verdict(domain.Action)) -> String {
  case verdict {
    Approve -> "approved"
    Correct(..) -> "corrected"
    Reject(..) -> "rejected"
  }
}

fn visibility_name(found: Result(domain.Visibility, Nil)) -> String {
  case found {
    Ok(domain.Pending) -> "pending"
    Ok(domain.Published) -> "published"
    Ok(domain.Hidden(reason)) -> "hidden for " <> domain.violation_name(reason)
    Ok(domain.WithSafetyTeam(_)) -> "with the safety team"
    Ok(domain.HiddenPendingReview(_)) -> "hidden pending review"
    Error(Nil) -> "unknown"
  }
}

/// Step 6: a senior corrects a card a moderator holds.
fn stale_card(a: App) -> Nil {
  io.println("6. A senior corrects a card a moderator is reading")
  let s = app.store_of(a)
  let handle = store.handle(s)
  desk.on_duty(person(a, "bruno"), False)
  desk.on_duty(person(a, "carla"), False)
  desk.pace(person(a, "ana"), 500)
  let before = desk.snapshot(person(a, "ana"))
  let insult = scripted.post(20_490)
  let assert Ok(_) = app.receive(a, insult)
  let key = wiring.key(insult)
  let assert True =
    app.wait_until(
      fn() {
        case store.get(handle, wiring.claims, key) {
          Ok("ana") -> True
          _ -> False
        }
      },
      within: 10_000,
    )
  let assert Ok(_) =
    desk.decide_now(
      s,
      app.desk_of(a),
      desk.senior("carla"),
      key,
      Correct(
        output: domain.Escalate("repeated harassment"),
        reason: Reason(category: "needs_safety_team", note: None),
      ),
    )
  // Her verdict on the card as she saw it is refused; the hints about the
  // card tell her to open it again, and she approves the correction.
  let assert True =
    app.wait_until(fn() { app.all_settled(a, [insult]) }, within: 10_000)
  let after = desk.snapshot(person(a, "ana"))
  let assert Ok(known) = decisions.read(app.desk_of(a), handle, occurrence: key)
  desk.pace(person(a, "ana"), 0)
  list.each(["bruno", "carla"], fn(name) { desk.on_duty(person(a, name), True) })
  say(
    "hiding for abuse needs two moderators; carla corrected the card to an escalation while ana read it",
  )
  say(
    "ana's verdict was refused as stale "
    <> count(after.stale - before.stale)
    <> " time; the hints that followed ("
    <> count(after.told - before.told)
    <> ") told her to open it again, and she approved the correction",
  )
  say(
    "verdicts on the record: "
    <> string.join(
      list.map(occurrence.verdicts(known), fn(pair) {
        pair.0 <> " " <> verdict_name(pair.1)
      }),
      ", ",
    )
    <> "; the post is "
    <> visibility_name(wiring.visibility(handle, insult.id)),
  )
  io.println("")
}

/// Steps 7 and 8: the operator's numbers and the invariant check.
fn report(a: App) -> Nil {
  io.println("7. What an operator watched (Sinal, the whole run)")
  let n: telemetry.Numbers = app.numbers(a)
  say(
    "received "
    <> count(n.received)
    <> ", duplicates "
    <> count(n.duplicates)
    <> ", by rules "
    <> count(n.by_rules)
    <> ", by classifier "
    <> count(n.by_classifier),
  )
  say(
    "proceeded "
    <> count(n.proceeded)
    <> ", waited "
    <> count(n.waited)
    <> ", sampled "
    <> count(n.sampled)
    <> ", reviewed "
    <> count(n.reviewed),
  )
  say(
    "approved "
    <> count(n.approved)
    <> ", corrected "
    <> count(n.corrected)
    <> ", stale cards "
    <> count(n.stale_cards)
    <> ", hints missed "
    <> count(n.hints_missed),
  )
  say(
    "deadlines hit "
    <> count(n.deadlines)
    <> ", raised "
    <> count(n.raised)
    <> ", jobs failed "
    <> count(n.jobs_failed)
    <> ", set aside "
    <> count(n.set_aside)
    <> ", settlements delivered "
    <> count(n.settlements)
    <> ", wake-ups "
    <> count(n.wakes),
  )
  let s = app.store_of(a)
  let checked =
    testing.check(store.handle(s), store.inspection(), [
      testing.audit(app.desk_of(a), effects: fn(tx) {
        Ok(store.count(tx, wiring.released))
      }),
    ])
  case checked {
    Ok(summary) ->
      io.println(
        "8. Invariants I1 to I8 hold over "
        <> count(summary.occurrences)
        <> " occurrences ("
        <> count(summary.released)
        <> " released)",
      )
    Error(violations) ->
      io.println(
        "8. Invariants broken: " <> string.inspect(list.take(violations, 5)),
      )
  }
  io.println("Everything above was in memory and is lost now that it stops.")
}
