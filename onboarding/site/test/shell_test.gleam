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

pub fn a_card_that_fits_settles_at_full_size_test() {
  let sample = fit.Sample("step", height: 500, bar: 100)
  let first = fit.next(Error(Nil), sample, "b", 700)
  assert first == fit.Settling(100, "b")
  assert fit.next(Ok(first), sample, "b", 700) == fit.Settled(100, "b", 500)
}

pub fn a_tall_card_starts_one_step_above_its_estimate_test() {
  // 1000 tall at 100%: 100 bar, 42 frame, 858 content. 800 available leaves
  // 658 for content: 658 / 858 = 76.7%, an estimate of 75%, so start at 85%.
  let sample = fit.Sample("step", height: 1000, bar: 100)
  assert fit.next(Error(Nil), sample, "b", 800) == fit.Settling(85, "b")
  // 600 available: the estimate is the 60% floor, so start at 70%.
  assert fit.next(Error(Nil), sample, "b", 600) == fit.Settling(70, "b")
}

pub fn a_settling_card_shrinks_by_five_until_it_fits_test() {
  let settling = fit.Settling(85, "b")
  let over = fit.Sample("step", height: 830, bar: 100)
  assert fit.next(Ok(settling), over, "b", 800) == fit.Settling(80, "b")
  let fits = fit.Sample("step", height: 790, bar: 100)
  assert fit.next(Ok(fit.Settling(80, "b")), fits, "b", 800)
    == fit.Settled(80, "b", 790)
  let floor = fit.Settling(60, "b")
  assert fit.next(Ok(floor), over, "b", 800) == fit.Settled(60, "b", 830)
}

pub fn a_settled_card_holds_its_zoom_test() {
  let settled = fit.Settled(80, "b", 790)
  let same = fit.Sample("step", height: 770, bar: 100)
  assert fit.next(Ok(settled), same, "b", 800) == settled
}

pub fn a_settled_card_shrinks_when_it_outgrows_the_screen_test() {
  let settled = fit.Settled(80, "b", 790)
  let grown = fit.Sample("step", height: 860, bar: 100)
  assert fit.next(Ok(settled), grown, "b", 800) == fit.Settling(75, "b")
}

pub fn a_settled_card_grows_back_when_its_content_shrinks_test() {
  let settled = fit.Settled(70, "b", 790)
  let shrunk = fit.Sample("step", height: 600, bar: 100)
  // content 458 at 70% is 654 at full; room 658 fits at 100%.
  assert fit.next(Ok(settled), shrunk, "b", 800) == fit.Settling(100, "b")
}

pub fn a_new_step_starts_settling_again_test() {
  let settled = fit.Settled(60, "old", 790)
  let sample = fit.Sample("step", height: 542, bar: 100)
  // content 400 at 60% is 666 at full; room 658 -> estimate 95%, start 100%.
  assert fit.next(Ok(settled), sample, "new", 800) == fit.Settling(100, "new")
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
