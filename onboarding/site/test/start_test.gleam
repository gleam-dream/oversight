import gleam/string
import lustre/element
import pages/start
import site/context
import site/motion
import site/progress

pub fn phase_times_add_up_their_modules_test() {
  let page =
    start.view(start.init(), context.new(motion.On, progress.empty()))
    |> element.to_string
  assert string.contains(page, "about 65 min")
  assert string.contains(page, "about 35 min")
  assert string.contains(page, "about 85 min")
  assert string.contains(page, "about 40 min")
}
