//// The shell around every page: the app bar with progress, motion and the
//// module menu; hash routing; done-marking; the module footer; and
//// fit-to-screen measurement for touring playgrounds.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/browser.{type Layout}
import site/context.{type Context, Context}
import site/fit.{type Fit}
import site/motion.{type Motion}
import site/pages.{type PageMsg, type Pages}
import site/progress.{type Progress}
import site/route.{type Module, type Route}
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type Menu {
  MenuClosed
  MenuOpen
}

pub type Model {
  Model(
    route: Route,
    menu: Menu,
    motion: Motion,
    progress: Progress,
    /// Observed: the zoom each touring playground of the current page needs.
    fits: Dict(String, Fit),
    pages: Pages,
  )
}

/// What the browser told us at start-up.
pub type Flags {
  Flags(
    hash: String,
    stored_progress: Result(String, Nil),
    stored_motion: Result(String, Nil),
    system_reduces_motion: Bool,
  )
}

pub type Msg {
  ReaderChangedHash(String)
  ReaderToggledMenu
  ReaderChoseFromMenu
  ReaderToggledMotion
  ReaderToggledDone(Module)
  ViewportResized
  ViewResized
  FontsLoaded
  LayoutMeasured(Layout)
  PageMsg(PageMsg)
}

pub fn init(flags: Flags) -> #(Model, Effect(Msg)) {
  let route = route.parse(flags.hash) |> result.unwrap(route.CourseMap)
  let model =
    Model(
      route:,
      menu: MenuClosed,
      motion: motion.initial(flags.stored_motion, flags.system_reduces_motion),
      progress: flags.stored_progress
        |> result.map(progress.decode)
        |> result.unwrap(progress.empty()),
      fits: dict.new(),
      pages: pages.init(),
    )
  let #(model, entered) = enter(model)
  #(
    model,
    effect.batch([
      entered,
      browser.listen_to_hash(ReaderChangedHash),
      browser.listen_to_resize(ViewportResized),
      browser.listen_to_view_resize(ViewResized),
      browser.when_fonts_ready(FontsLoaded),
      browser.set_title(route.document_title(route)),
      measure(),
    ]),
  )
}

pub fn context(model: Model) -> Context {
  Context(
    motion: model.motion,
    progress: model.progress,
    zooms: dict.map_values(model.fits, fn(_, fit) { fit.zoom }),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ReaderChangedHash(hash) ->
      case route.parse(hash) {
        Ok(route) if route != model.route -> navigate(model, route)
        _ -> #(model, effect.none())
      }

    ReaderToggledMenu -> {
      let menu = case model.menu {
        MenuOpen -> MenuClosed
        MenuClosed -> MenuOpen
      }
      #(Model(..model, menu:), effect.none())
    }

    ReaderChoseFromMenu -> #(Model(..model, menu: MenuClosed), effect.none())

    ReaderToggledMotion -> {
      let motion = motion.toggle(model.motion)
      let #(model, entered) =
        Model(..model, motion:, pages: pages.leave(model.pages, model.route))
        |> enter
      #(
        model,
        effect.batch([
          entered,
          browser.write(motion.storage_key, motion.encode(motion)),
          measure(),
        ]),
      )
    }

    ReaderToggledDone(module) -> {
      let progress = progress.toggle(model.progress, module)
      #(
        Model(..model, progress:),
        browser.write(progress.storage_key, progress.encode(progress)),
      )
    }

    ViewportResized | ViewResized -> #(model, measure())

    FontsLoaded -> #(Model(..model, fits: dict.new()), measure())

    LayoutMeasured(layout) -> {
      let fits = refit(model.fits, layout)
      let settling = list.any(dict.values(fits), fit.is_settling)
      let effect = case settling || zooms(fits) != zooms(model.fits) {
        True -> measure()
        False -> effect.none()
      }
      #(Model(..model, fits:), effect)
    }

    PageMsg(msg) -> {
      let #(pages, effect) = pages.update(model.pages, msg, context(model))
      #(
        Model(..model, pages:),
        effect.batch([effect.map(effect, PageMsg), measure()]),
      )
    }
  }
}

fn navigate(model: Model, to: Route) -> #(Model, Effect(Msg)) {
  let #(model, entered) =
    Model(
      ..model,
      route: to,
      menu: MenuClosed,
      fits: dict.new(),
      pages: pages.leave(model.pages, model.route),
    )
    |> enter
  #(
    model,
    effect.batch([
      entered,
      browser.set_title(route.document_title(to)),
      browser.show_page_from_top("view"),
      measure(),
    ]),
  )
}

/// Let the current page react to the reader arriving.
fn enter(model: Model) -> #(Model, Effect(Msg)) {
  let #(pages, effect) = pages.enter(model.pages, model.route, context(model))
  #(Model(..model, pages:), effect.map(effect, PageMsg))
}

fn measure() -> Effect(Msg) {
  browser.measure(LayoutMeasured)
}

/// Fit every touring playground that was measured; playgrounds that stopped
/// touring drop out. Narrow screens are never scaled.
pub fn refit(fits: Dict(String, Fit), layout: Layout) -> Dict(String, Fit) {
  case layout.width < fit.narrow_width {
    True -> dict.new()
    False ->
      list.fold(layout.labs, dict.new(), fn(next, lab) {
        let basis = fit.basis(lab.narration, layout.width, layout.height)
        let sample = fit.Sample(height: lab.height, shown: lab.zoom)
        dict.insert(
          next,
          lab.tour,
          fit.next(dict.get(fits, lab.tour), sample, basis, layout.available),
        )
      })
  }
}

fn zooms(fits: Dict(String, Fit)) -> Dict(String, Int) {
  dict.map_values(fits, fn(_, fit) { fit.zoom })
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [class("pg"), attribute.classes([#("still", model.motion == motion.Off)])],
    [
      app_bar(model),
      html.main([attribute.id("view"), attribute("tabindex", "-1")], [
        pages.view(model.pages, model.route, context(model))
        |> element.map(PageMsg),
      ]),
      footer(model),
    ],
  )
}

fn app_bar(model: Model) -> Element(Msg) {
  let done = progress.count(model.progress)
  let total = list.length(route.modules)
  let open = model.menu == MenuOpen
  let motion_label = case model.motion {
    motion.On -> "Motion: on"
    motion.Off -> "Motion: off"
  }
  html.header([class("appbar")], [
    html.div([class("appin")], [
      html.a([class("brand"), attribute.href("#start")], [
        html.text("gleam-dream / onboarding"),
      ]),
      html.div([class("prog"), attribute("aria-live", "polite")], [
        html.div([class("progbar"), attribute("aria-hidden", "true")], [
          html.span(
            [
              attribute.id("pbar"),
              css(
                "width:"
                <> int.to_string(progress.percent(model.progress))
                <> "%",
              ),
            ],
            [],
          ),
        ]),
        html.span([class("meta"), attribute.id("ptext")], [
          html.text(
            int.to_string(done) <> " of " <> int.to_string(total) <> " done",
          ),
        ]),
      ]),
      html.div([class("row"), css("gap:8px")], [
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            attribute.id("motionBtn"),
            ui.pressed(motion.is_on(model.motion)),
            attribute.title("Turn animations and auto-play on or off"),
            event.on_click(ReaderToggledMotion),
          ],
          [html.text(motion_label)],
        ),
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            attribute.id("menuBtn"),
            attribute("aria-expanded", case open {
              True -> "true"
              False -> "false"
            }),
            attribute("aria-controls", "drawer"),
            event.on_click(ReaderToggledMenu),
          ],
          [
            html.text(case open {
              True -> "Close"
              False -> "All modules"
            }),
          ],
        ),
      ]),
    ]),
    html.nav(
      [
        attribute.id("drawer"),
        class("drawer"),
        attribute.aria_label("Modules"),
        attribute.hidden(!open),
      ],
      list.map(route.all(), menu_entry(model, _)),
    ),
  ])
}

fn menu_entry(model: Model, entry: Route) -> Element(Msg) {
  let current = entry == model.route
  let #(status, done) = case entry {
    route.CourseMap -> #("start", False)
    route.Module(module) ->
      case progress.is_done(model.progress, module) {
        True -> #("✓ done", True)
        False -> #(int.to_string(route.minutes(module)) <> " min", False)
      }
  }
  html.a(
    [
      attribute.href(route.href(entry)),
      attribute.classes([#("cur", current)]),
      case current {
        True -> attribute("aria-current", "page")
        False -> attribute.none()
      },
      event.on_click(ReaderChoseFromMenu),
    ],
    [
      html.span([], [html.text(route.label(entry))]),
      html.span([class("dn"), attribute.classes([#("ok", done)])], [
        html.text(status),
      ]),
    ],
  )
}

fn footer(model: Model) -> Element(Msg) {
  case model.route {
    route.CourseMap ->
      html.footer(
        [attribute.id("foot"), class("wrap foot"), attribute.hidden(True)],
        [],
      )
    route.Module(module) -> module_footer(model, module)
  }
}

fn module_footer(model: Model, module: Module) -> Element(Msg) {
  let n = int.to_string(route.number(module))
  let done = progress.is_done(model.progress, module)
  html.footer([attribute.id("foot"), class("wrap foot")], [
    html.div(
      [
        class("row"),
        css("justify-content:space-between;gap:16px;margin-bottom:24px"),
      ],
      [
        html.div([], [
          html.div([class("k")], [html.text("Finished module " <> n <> "?")]),
        ]),
        html.button(
          [
            attribute.type_("button"),
            ui.on_class("donebtn", done),
            ui.pressed(done),
            event.on_click(ReaderToggledDone(module)),
          ],
          [
            html.text(case done {
              True -> "✓ Marked as done"
              False -> "Mark module " <> n <> " as done"
            }),
          ],
        ),
      ],
    ),
    html.div([class("row"), css("gap:16px;align-items:stretch")], [
      nav_card(route.previous(module), "← Previous", ""),
      nav_card(route.next(module), "Next →", "text-align:right"),
    ]),
    html.p([class("meta"), css("margin-top:24px")], [
      html.text("Built from the gleam-dream repositories on "),
      ui.external("https://github.com/gleam-dream", [], [html.text("GitHub")]),
      html.text("."),
    ]),
  ])
}

fn nav_card(to: Route, direction: String, style: String) -> Element(Msg) {
  html.a([class("navc"), attribute.href(route.href(to)), css(style)], [
    html.span([class("meta")], [html.text(direction)]),
    html.span([css("font:600 19px 'Space Grotesk',sans-serif")], [
      html.text(route.label(to)),
    ]),
  ])
}
