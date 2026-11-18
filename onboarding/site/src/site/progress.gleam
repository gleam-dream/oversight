//// Which modules the reader has marked done. Only modules can be done; the
//// stored form is the reference's `{"<slug>": 1}` object so the key and shape
//// stay stable.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/set.{type Set}
import site/route.{type Module}

pub opaque type Progress {
  Progress(done: Set(Module))
}

pub const storage_key = "gd-onboarding-done-v1"

pub fn empty() -> Progress {
  Progress(set.new())
}

pub fn is_done(progress: Progress, module: Module) -> Bool {
  set.contains(progress.done, module)
}

pub fn toggle(progress: Progress, module: Module) -> Progress {
  case is_done(progress, module) {
    True -> Progress(set.delete(progress.done, module))
    False -> Progress(set.insert(progress.done, module))
  }
}

pub fn count(progress: Progress) -> Int {
  set.size(progress.done)
}

/// Whole percent of the eleven modules, rounded like the reference bar.
pub fn percent(progress: Progress) -> Int {
  let total = list.length(route.modules)
  { count(progress) * 200 + total } / { total * 2 }
}

pub fn encode(progress: Progress) -> String {
  route.modules
  |> list.filter(is_done(progress, _))
  |> list.map(fn(module) { #(route.module_slug(module), json.int(1)) })
  |> json.object
  |> json.to_string
}

/// Decode stored progress. Anything unreadable, and any key that is not a
/// module, is dropped rather than failing the page.
pub fn decode(stored: String) -> Progress {
  case json.parse(stored, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) ->
      entries
      |> dict.keys
      |> list.filter_map(route.parse_module)
      |> set.from_list
      |> Progress
    Error(_) -> empty()
  }
}
