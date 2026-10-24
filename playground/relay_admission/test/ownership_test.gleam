import gleeunit/should
import ownership_probe

pub fn short_lived_worker_changes_subject_ownership_test() {
  ownership_probe.mailbox()
  |> should.equal(ownership_probe.MailboxObservation(True, False, False))
}

pub fn killing_worker_does_not_clean_arbitrary_children_test() {
  ownership_probe.kill_callback()
  |> should.equal(ownership_probe.CleanupObservation(False, True, True, True))
}
