//// Disposable TLS material for the scripted OpenID provider.
////
//// Warden requires an `https` issuer and verifies TLS against configured
//// trust anchors, so the local provider needs a certificate for `localhost`
//// issued by a root the portal trusts. It is generated at startup (no
//// OpenSSL, no checked-in keys) and written to a temporary directory because
//// `mist.with_tls` only accepts file paths.

import gleam/int
import gleam/result
import simplifile

pub type Pki {
  Pki(
    /// PEM text of the root certificate: Warden's trust anchor.
    certificate_pem: String,
    /// DER bytes of the same root, for `http_gun` trust.
    certificate_der: BitArray,
    certfile: String,
    keyfile: String,
  )
}

/// A P-256 root and a `localhost`/`127.0.0.1` server certificate.
pub fn generate(directory: String) -> Result(Pki, String) {
  let dir = directory <> "/pki-" <> int.to_string(int.random(1_000_000_000))
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.replace_error("cannot create " <> dir),
  )
  let #(certificate_pem, certificate_der, certfile, keyfile) = ffi_generate(dir)
  Ok(Pki(certificate_pem:, certificate_der:, certfile:, keyfile:))
}

@external(erlang, "sso_portal_pki_ffi", "generate")
fn ffi_generate(directory: String) -> #(String, BitArray, String, String)
