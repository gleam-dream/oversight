import gleam/dict
import gleam/list
import site/app
import site/browser
import site/fit
import site/motion
import site/progress
import site/route

// ROUTES ----------------------------------------------------------------------

pub fn every_route_round_trips_through_its_hash_test() {
  list.each(route.all(), fn(r) {
    assert route.parse(route.href(r)) == Ok(r)
    assert route.parse(route.slug(r)) == Ok(r)
  })
}

pub fn unknown_hashes_are_not_routes_test() {
  assert route.parse("#sinal") == Error(Nil)
  assert route.parse("") == Error(Nil)
}

pub fn modules_link_to_neighbours_and_wrap_to_the_map_test() {
  assert route.previous(route.Beam) == route.CourseMap
  assert route.next(route.Beam) == route.Module(route.Otp)
  assert route.previous(route.FieldGuide) == route.Module(route.Compose)
  assert route.next(route.FieldGuide) == route.CourseMap
}

pub fn module_minutes_sum_to_the_course_length_test() {
  assert list.fold(route.modules, 0, fn(sum, m) { sum + route.minutes(m) })
    == 215
}

pub fn document_titles_name_the_place_test() {
  assert route.document_title(route.CourseMap)
    == "Course map · gleam-dream onboarding"
  assert route.document_title(route.Module(route.Gleam))
    == "Module 3 · Gleam · gleam-dream onboarding"
}

// PROGRESS --------------------------------------------------------------------

pub fn progress_toggles_and_counts_test() {
  let p =
    progress.empty()
    |> progress.toggle(route.Beam)
    |> progress.toggle(route.Atlas)
  assert progress.count(p) == 2
  assert progress.is_done(p, route.Beam)
  assert !progress.is_done(progress.toggle(p, route.Beam), route.Beam)
}

pub fn progress_percent_rounds_like_the_reference_test() {
  let one = progress.toggle(progress.empty(), route.Beam)
  // 1 of 11 is 9.09%, 6 of 11 is 54.5%
  assert progress.percent(one) == 9
  let six =
    list.take(route.modules, 6)
    |> list.fold(progress.empty(), progress.toggle)
  assert progress.percent(six) == 55
}

pub fn progress_survives_storage_test() {
  let p =
    progress.empty()
    |> progress.toggle(route.OutsideWorld)
    |> progress.toggle(route.FieldGuide)
  assert progress.encode(p) == "{\"outside-world\":1,\"field-guide\":1}"
  assert progress.decode(progress.encode(p)) == p
}

pub fn stored_progress_drops_what_it_cannot_read_test() {
  let p = progress.decode("{\"beam\":1,\"start\":1,\"quiz\":1}")
  assert progress.count(p) == 1
  assert progress.is_done(p, route.Beam)
  assert progress.decode("not json") == progress.empty()
}

// MOTION ----------------------------------------------------------------------

pub fn a_remembered_motion_choice_wins_over_the_system_test() {
  assert motion.initial(Ok("on"), True) == motion.On
  assert motion.initial(Ok("off"), False) == motion.Off
  assert motion.initial(Error(Nil), True) == motion.Off
  assert motion.initial(Error(Nil), False) == motion.On
  assert motion.initial(Ok("garbage"), True) == motion.Off
}

// FIT TO SCREEN ---------------------------------------------------------------

/// Run the fit against a card whose height at each zoom is `height(zoom)`,
/// one measurement per render, until it settles.
fn settle(height: fn(Int) -> Int, available: Int) -> #(Int, Int) {
  settle_loop(Error(Nil), height, available, 0)
}

fn settle_loop(
  previous: Result(fit.Fit, Nil),
  height: fn(Int) -> Int,
  available: Int,
  renders: Int,
) -> #(Int, Int) {
  let shown = case previous {
    Ok(f) -> f.zoom
    Error(Nil) -> 100
  }
  let sample = fit.Sample(height: height(shown), shown:)
  let next = fit.next(previous, sample, "b", available)
  case fit.is_settling(next) && renders < 20 {
    True -> settle_loop(Ok(next), height, available, renders + 1)
    False -> #(next.zoom, renders)
  }
}

/// The reference's answer: walk down from 100% until the card fits.
fn top_down(height: fn(Int) -> Int, available: Int, zoom: Int) -> Int {
  case height(zoom) > available && zoom > fit.floor {
    True -> top_down(height, available, zoom - 5)
    False -> zoom
  }
}

pub fn the_fit_finds_the_first_zoom_that_fits_from_the_top_test() {
  let cards = [
    fn(z) { 142 + 858 * z / 100 },
    fn(z) { 142 + 900 * z / 100 - { 100 - z } * 6 },
    fn(z) { 142 + 1400 * z / 100 },
    fn(z) { 142 + 400 * z / 100 },
    // Not monotonic: at 85% the layout wraps and the card grows, as the
    // BEAM process playground does at 1440x900.
    fn(z) {
      case z {
        100 -> 908
        95 -> 857
        90 -> 804
        85 -> 837
        _ -> 736
      }
    },
  ]
  list.each(cards, fn(height) {
    list.each([600, 700, 750, 800, 827, 900], fn(available) {
      let #(zoom, renders) = settle(height, available)
      assert zoom == top_down(height, available, 100)
      assert renders <= 9
    })
  })
}

pub fn a_card_that_fits_at_full_size_settles_at_once_test() {
  let sample = fit.Sample(height: 500, shown: 100)
  assert fit.next(Error(Nil), sample, "b", 700) == fit.Settled(100, "b", 500)
}

pub fn a_new_step_walks_down_from_full_size_test() {
  let settled = fit.Settled(80, "old", 790)
  let sample = fit.Sample(height: 500, shown: 80)
  assert fit.next(Ok(settled), sample, "new", 800) == fit.Trying(100, "new")
}

pub fn a_measurement_from_before_the_zoom_applied_is_ignored_test() {
  let trying = fit.Trying(85, "b")
  let stale = fit.Sample(height: 900, shown: 90)
  assert fit.next(Ok(trying), stale, "b", 800) == trying
}

pub fn a_settled_card_holds_its_zoom_test() {
  let settled = fit.Settled(80, "b", 790)
  assert fit.next(Ok(settled), fit.Sample(770, 80), "b", 800) == settled
}

pub fn a_settled_card_keeps_walking_down_when_it_outgrows_the_screen_test() {
  let settled = fit.Settled(80, "b", 790)
  assert fit.next(Ok(settled), fit.Sample(860, 80), "b", 800)
    == fit.Trying(75, "b")
}

pub fn a_settled_card_walks_again_when_its_content_shrinks_test() {
  let settled = fit.Settled(70, "b", 790)
  assert fit.next(Ok(settled), fit.Sample(600, 70), "b", 800)
    == fit.Trying(100, "b")
}

pub fn the_floor_holds_test() {
  let trying = fit.Trying(60, "b")
  assert fit.next(Ok(trying), fit.Sample(900, 60), "b", 800)
    == fit.Settled(60, "b", 900)
}

pub fn narrow_screens_are_never_scaled_test() {
  let lab = browser.MeasuredLab("stack", "step", 2000, 100)
  let wide =
    browser.Layout(width: 1366, height: 768, available: 700, labs: [lab])
  let narrow = browser.Layout(..wide, width: 600)
  assert dict.size(app.refit(dict.new(), wide)) == 1
  assert dict.size(app.refit(dict.new(), narrow)) == 0
}

pub fn playgrounds_that_stop_touring_drop_their_fit_test() {
  let lab = browser.MeasuredLab("stack", "step", 2000, 100)
  let touring =
    browser.Layout(width: 1366, height: 768, available: 700, labs: [lab])
  let fits = app.refit(dict.new(), touring)
  let free = browser.Layout(..touring, labs: [])
  assert app.refit(fits, free) == dict.new()
}
