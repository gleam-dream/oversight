//// Entry point: read what the browser knows, register the real-time widget
//// components, then start the site.

import lustre
import site/app
import site/browser
import site/motion
import site/pages
import site/progress

pub fn main() -> Nil {
  let flags =
    app.Flags(
      hash: browser.location_hash(),
      stored_progress: browser.storage_get(progress.storage_key),
      stored_motion: browser.storage_get(motion.storage_key),
      system_reduces_motion: browser.prefers_reduced_motion(),
    )
  let assert Ok(Nil) = pages.register_components()
  let app = lustre.application(app.init, app.update, app.view)
  let assert Ok(_) = lustre.start(app, "#app", flags)
  Nil
}
