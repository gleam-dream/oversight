//// Compiler-only declarations; no disk, playback, or recording implementation.

import http_gun

pub type Cassette

pub type Recording

pub type Error {
  InvalidFixture
  UnsupportedVersion(version: Int)
  StorageFailure(reason: String)
}

@external(erlang, "http_gun_probe_only", "load")
pub fn load(path: String, max_bytes: Int) -> Result(Cassette, Error)

@external(erlang, "http_gun_probe_only", "playback")
pub fn playback(
  cassette: Cassette,
  settings: http_gun.Settings,
) -> Result(http_gun.Client, Error)

@external(erlang, "http_gun_probe_only", "record")
pub fn record(
  live: http_gun.Client,
  path: String,
  max_bytes: Int,
) -> Result(#(http_gun.Client, Recording), Error)

@external(erlang, "http_gun_probe_only", "finish")
pub fn finish(recording: Recording) -> Result(Nil, Error)
