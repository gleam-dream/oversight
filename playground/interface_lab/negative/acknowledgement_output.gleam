import lab/grind_claim as claim

pub fn invalid(
  command: claim.AckCommand(String, Nil, Nil),
) -> claim.AckCommand(Int, Nil, Nil) {
  command
}
