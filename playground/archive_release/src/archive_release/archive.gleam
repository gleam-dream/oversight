import archive_release/domain.{
  type ApprovalPolicy, type Document, type Principal, type Release, Document,
  Revision,
}
import gleam/bool
import gleam/dynamic/decode
import gleam/result
import pog

pub type Context {
  Context(
    db: pog.Connection,
    principal: Principal,
    document: Document,
    permission: Bool,
    approval_policy: ApprovalPolicy,
  )
}

pub type WriteError {
  CurrentStateRefused
  Database(pog.QueryError)
}

pub fn migrate(db: pog.Connection) {
  execute(
    db,
    "CREATE TABLE IF NOT EXISTS archive_documents (id text PRIMARY KEY, revision bigint NOT NULL, content text NOT NULL)",
  )
  execute(
    db,
    "CREATE TABLE IF NOT EXISTS archive_permissions (issuer text NOT NULL, subject text NOT NULL, document text NOT NULL, PRIMARY KEY (issuer, subject, document))",
  )
  execute(
    db,
    "CREATE TABLE IF NOT EXISTS archive_releases (document text NOT NULL, revision bigint NOT NULL, content text NOT NULL, issuer text NOT NULL, subject text NOT NULL, PRIMARY KEY (document, revision))",
  )
}

pub fn execute(db: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) = pog.query(sql) |> pog.execute(db)
  Nil
}

pub fn seed(
  db: pog.Connection,
  principal: Principal,
  id: String,
  content: String,
) -> Nil {
  let assert Ok(_) =
    pog.query("INSERT INTO archive_documents VALUES ($1, 1, $2)")
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(content))
    |> pog.execute(db)
  let assert Ok(_) =
    pog.query("INSERT INTO archive_permissions VALUES ($1, $2, $3)")
    |> pog.parameter(pog.text(principal.issuer))
    |> pog.parameter(pog.text(principal.subject))
    |> pog.parameter(pog.text(id))
    |> pog.execute(db)
  Nil
}

pub fn context(
  db: pog.Connection,
  principal: Principal,
  id: String,
  approval_policy: ApprovalPolicy,
) -> Context {
  let decoder = {
    use revision <- decode.field(0, decode.int)
    use content <- decode.field(1, decode.string)
    use allowed <- decode.field(2, decode.bool)
    decode.success(#(revision, content, allowed))
  }
  let assert Ok(rows) =
    pog.query(
      "SELECT revision, content, EXISTS (SELECT 1 FROM archive_permissions p WHERE p.document=d.id AND p.issuer=$2 AND p.subject=$3) FROM archive_documents d WHERE id=$1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(principal.issuer))
    |> pog.parameter(pog.text(principal.subject))
    |> pog.returning(decoder)
    |> pog.execute(db)
  let assert [#(revision, content, permission)] = rows.rows
  Context(
    db,
    principal,
    Document(id, Revision(revision), content, domain.classify(content)),
    permission,
    approval_policy,
  )
}

/// SQL checks current permission and exact revision at the write boundary.
/// The unique key is application effect identity independent of Fabric retention.
pub fn release(
  context: Context,
  release: Release,
) -> Result(Release, WriteError) {
  use <- bool.guard(
    release.requester != context.principal,
    Error(CurrentStateRefused),
  )
  let query =
    pog.query(
      "INSERT INTO archive_releases (document, revision, content, issuer, subject) SELECT d.id, d.revision, d.content, $3, $4 FROM archive_documents d WHERE d.id=$1 AND d.revision=$2 AND EXISTS (SELECT 1 FROM archive_permissions p WHERE p.document=d.id AND p.issuer=$3 AND p.subject=$4) ON CONFLICT (document, revision) DO NOTHING RETURNING document",
    )
    |> pog.parameter(pog.text(release.document))
    |> pog.parameter(pog.int(release.revision.number))
    |> pog.parameter(pog.text(context.principal.issuer))
    |> pog.parameter(pog.text(context.principal.subject))
    |> pog.returning(decode.field(0, decode.string, decode.success))
  use rows <- result.try(
    pog.execute(query, context.db) |> result.map_error(Database),
  )
  case rows.rows {
    [_] -> Ok(release)
    _ -> Error(CurrentStateRefused)
  }
}

pub fn releases(
  db: pog.Connection,
  id: String,
) -> List(#(Int, String, String)) {
  let decoder = {
    use revision <- decode.field(0, decode.int)
    use content <- decode.field(1, decode.string)
    use subject <- decode.field(2, decode.string)
    decode.success(#(revision, content, subject))
  }
  let assert Ok(rows) =
    pog.query(
      "SELECT revision, content, subject FROM archive_releases WHERE document=$1 ORDER BY revision",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(decoder)
    |> pog.execute(db)
  rows.rows
}
