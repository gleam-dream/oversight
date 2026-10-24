import archive_release/archive
import archive_release/auth
import archive_release/domain
import fabric/store
import fabric_postgres
import gleam/erlang/process
import hellhound
import hellhound/config
import hellhound/resource
import hellhound/testing
import pog

pub type Fixture {
  Fixture(
    provider: testing.Provider,
    validator: resource.Validator,
    token: String,
    principal: domain.Principal,
    db: pog.Connection,
    settings: fabric_postgres.Settings,
  )
}

@external(erlang, "archive_release_test_ffi", "database_url")
fn database_url() -> String

@external(erlang, "archive_release_test_ffi", "finally")
fn finally(cleanup: fn() -> Nil, work: fn() -> a) -> a

@external(erlang, "archive_release_test_ffi", "stop_process")
fn stop_process(pid: process.Pid) -> Nil

pub fn using(work: fn(Fixture) -> a) -> a {
  let assert Ok(provider) = testing.start_provider(testing.provider_options())
  use <- finally(fn() { testing.stop_provider(provider) })
  let assert Ok(client) =
    hellhound.new(
      config.resource_server(testing.issuer(provider))
      |> testing.trusting(provider),
    )
  let assert Ok(Nil) = hellhound.start(client)
  use <- finally(fn() { hellhound.stop(client) })
  let validator = resource.new(client, auth.audience)
  let token = token(provider, ["archive:release", "approve:archive-review"])
  let assert Ok(principal) = auth.admit(validator, token)
  let assert Ok(pool_config) =
    pog.url_config(process.new_name("archive_pool"), database_url())
  let assert Ok(pool) = pog.start(pool_config)
  use <- finally(fn() { stop_process(pool.pid) })
  let db = pool.data
  archive.migrate(db)
  let settings = fabric_postgres.settings(db, "archive-node")
  let assert Ok(Nil) = fabric_postgres.migrate(settings)
  work(Fixture(provider, validator, token, principal, db, settings))
}

pub fn token(provider: testing.Provider, scopes: List(String)) -> String {
  testing.issue_access_token(
    provider,
    testing.access_token("archivist")
      |> testing.with_audiences([auth.audience])
      |> testing.with_scopes(scopes),
  )
}

pub fn using_store(
  settings: fabric_postgres.Settings,
  work: fn(store.Store) -> a,
) -> a {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("archive_store"), settings)
  let assert Ok(Nil) = store.start(runs)
  use <- finally(fn() {
    let assert Ok(Nil) = store.stop(runs)
    Nil
  })
  work(runs)
}
