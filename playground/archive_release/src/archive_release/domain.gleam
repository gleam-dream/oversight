import json/blueprint/codec

pub type Revision {
  Revision(number: Int)
}

pub type Classification {
  Public
  Embargoed
}

pub type Document {
  Document(
    id: String,
    revision: Revision,
    content: String,
    classification: Classification,
  )
}

pub type Principal {
  Principal(issuer: String, subject: String)
}

pub type Release {
  Release(document: String, revision: Revision, requester: Principal)
}

pub type ApprovalPolicy {
  EmbargoOnly
  EveryRelease
}

/// A deterministic classifier fixture; classification is application policy.
pub fn classify(content: String) -> Classification {
  case content {
    "public minutes" -> Public
    _ -> Embargoed
  }
}

pub fn release_codec() -> codec.Codec(Release) {
  use document <- codec.field("document", codec.string(), get: fn(r) {
    r.document
  })
  use revision <- codec.field(
    "revision",
    codec.map(codec.int(), decode: Revision, encode: fn(r) { r.number }),
    get: fn(r) { r.revision },
  )
  use requester <- codec.field("requester", principal_codec(), get: fn(r) {
    r.requester
  })
  codec.success(Release(document:, revision:, requester:))
}

fn principal_codec() -> codec.Codec(Principal) {
  use issuer <- codec.field("issuer", codec.string(), get: fn(p) { p.issuer })
  use subject <- codec.field("subject", codec.string(), get: fn(p) { p.subject })
  codec.success(Principal(issuer:, subject:))
}
