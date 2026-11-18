//// Typed access to the browser APIs the site uses, as plain functions and as
//// Lustre effects. No page logic lives here.

import gleam/list
import lustre/effect.{type Effect}

pub type Measured {
  /// A playground card that is touring, as laid out right now.
  MeasuredLab(
    tour: String,
    narration: String,
    height: Int,
    /// The zoom the card showed when it was measured.
    zoom: Int,
  )
}

/// The viewport and every touring card, measured after a paint.
pub type Layout {
  Layout(width: Int, height: Int, available: Int, labs: List(Measured))
}

@external(javascript, "./browser.ffi.mjs", "storage_get")
fn do_storage_get(key: String) -> #(Bool, String)

pub fn storage_get(key: String) -> Result(String, Nil) {
  case do_storage_get(key) {
    #(True, value) -> Ok(value)
    #(False, _) -> Error(Nil)
  }
}

@external(javascript, "./browser.ffi.mjs", "storage_set")
pub fn storage_set(key: String, value: String) -> Nil

@external(javascript, "./browser.ffi.mjs", "prefers_reduced_motion")
pub fn prefers_reduced_motion() -> Bool

@external(javascript, "./browser.ffi.mjs", "location_hash")
pub fn location_hash() -> String

@external(javascript, "./browser.ffi.mjs", "on_hash_change")
fn on_hash_change(callback: fn(String) -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "on_resize")
fn on_resize(callback: fn() -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "on_fonts_ready")
fn on_fonts_ready(callback: fn() -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "on_view_resize")
fn on_view_resize(callback: fn() -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "set_timeout")
fn set_timeout(ms: Int, callback: fn() -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "set_document_title")
fn set_document_title(title: String) -> Nil

@external(javascript, "./browser.ffi.mjs", "scroll_to_top")
fn scroll_to_top() -> Nil

@external(javascript, "./browser.ffi.mjs", "focus_without_scroll")
fn focus_without_scroll(id: String) -> Nil

@external(javascript, "./browser.ffi.mjs", "scroll_into_view")
fn scroll_into_view(id: String, smooth: Bool) -> Nil

@external(javascript, "./browser.ffi.mjs", "scroll_under_app_bar")
fn scroll_under_app_bar(selector: String, smooth: Bool) -> Nil

@external(javascript, "./browser.ffi.mjs", "measure_labs")
fn do_measure_labs() -> #(Int, Int, Int, List(#(String, String, Int, Int)))

@external(javascript, "./browser.ffi.mjs", "subscribe_frames")
fn do_subscribe_frames(callback: fn(Float) -> Nil) -> Int

@external(javascript, "./browser.ffi.mjs", "unsubscribe_frames")
fn do_unsubscribe_frames(id: Int) -> Nil

// EFFECTS ---------------------------------------------------------------------

/// Deliver every hash change, starting from now.
pub fn listen_to_hash(to_msg: fn(String) -> msg) -> Effect(msg) {
  use dispatch <- effect.from
  on_hash_change(fn(hash) { dispatch(to_msg(hash)) })
}

pub fn listen_to_resize(msg: msg) -> Effect(msg) {
  use dispatch <- effect.from
  on_resize(fn() { dispatch(msg) })
}

/// Deliver `msg` whenever the page view changes size, after it is painted.
pub fn listen_to_view_resize(msg: msg) -> Effect(msg) {
  use dispatch, _ <- effect.after_paint
  on_view_resize(fn() { dispatch(msg) })
}

pub fn when_fonts_ready(msg: msg) -> Effect(msg) {
  use dispatch <- effect.from
  on_fonts_ready(fn() { dispatch(msg) })
}

/// Dispatch `msg` once, `ms` milliseconds from now.
pub fn after(ms: Int, msg: msg) -> Effect(msg) {
  use dispatch <- effect.from
  set_timeout(ms, fn() { dispatch(msg) })
}

pub fn write(key: String, value: String) -> Effect(msg) {
  use _ <- effect.from
  storage_set(key, value)
}

pub fn set_title(title: String) -> Effect(msg) {
  use _ <- effect.from
  set_document_title(title)
}

/// Show a new page from its top and move focus to it without scrolling.
pub fn show_page_from_top(focus_id: String) -> Effect(msg) {
  use _, _ <- effect.after_paint
  scroll_to_top()
  focus_without_scroll(focus_id)
}

pub fn jump_to(id: String, smooth: Bool) -> Effect(msg) {
  use _ <- effect.from
  scroll_into_view(id, smooth)
}

/// Bring a playground card to sit just under the app bar.
pub fn bring_under_app_bar(tour: String, smooth: Bool) -> Effect(msg) {
  use _ <- effect.from
  scroll_under_app_bar("#view [data-tid=\"" <> tour <> "\"]", smooth)
}

/// Measure the layout of the rendered view before the browser paints it. A
/// message dispatched here is rendered again within the same frame.
pub fn measure(to_msg: fn(Layout) -> msg) -> Effect(msg) {
  use dispatch, _ <- effect.before_paint
  let #(width, height, available, labs) = do_measure_labs()
  let labs = {
    use #(tour, narration, height, zoom) <- list.map(labs)
    MeasuredLab(tour:, narration:, height:, zoom:)
  }
  dispatch(to_msg(Layout(width:, height:, available:, labs:)))
}

/// Subscribe to the shared animation loop. The callback receives the seconds
/// since the previous frame, capped at 0.05. Returns a handle for `unsubscribe`.
pub fn subscribe_frames(on_frame: fn(Float) -> Nil) -> Int {
  do_subscribe_frames(on_frame)
}

pub fn unsubscribe_frames(handle: Int) -> Nil {
  do_unsubscribe_frames(handle)
}
