// THROWAWAY: Can an ordinary web consumer require a verified identity?
import lab/warden

pub fn profile(identity: warden.VerifiedIdentity) -> String {
  warden.subject(identity)
}

pub fn callback(
  pending: warden.PendingLogin,
  callback: String,
) -> Result(String, warden.VerificationError) {
  case warden.verify_callback(pending, callback) {
    Ok(identity) -> Ok(profile(identity))
    Error(e) -> Error(e)
  }
}
