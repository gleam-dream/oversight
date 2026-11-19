//// Every page's state, kept for the whole visit so a reader who comes back
//// to a module finds its playgrounds as they left them.

import gleam/list
import gleam/result
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import pages/agents
import pages/atlas
import pages/beam
import pages/compose
import pages/durable_work
import pages/field_guide
import pages/foundations
import pages/gleam_lang
import pages/otp
import pages/outside_world
import pages/principles
import pages/start
import site/context.{type Context}
import site/route.{type Route}

pub type Pages {
  Pages(
    start: start.Model,
    beam: beam.Model,
    otp: otp.Model,
    gleam: gleam_lang.Model,
    principles: principles.Model,
    atlas: atlas.Model,
    foundations: foundations.Model,
    outside_world: outside_world.Model,
    durable_work: durable_work.Model,
    agents: agents.Model,
    compose: compose.Model,
    field_guide: field_guide.Model,
  )
}

pub type PageMsg {
  StartMsg(start.Msg)
  BeamMsg(beam.Msg)
  OtpMsg(otp.Msg)
  GleamMsg(gleam_lang.Msg)
  PrinciplesMsg(principles.Msg)
  AtlasMsg(atlas.Msg)
  FoundationsMsg(foundations.Msg)
  OutsideWorldMsg(outside_world.Msg)
  DurableWorkMsg(durable_work.Msg)
  AgentsMsg(agents.Msg)
  ComposeMsg(compose.Msg)
  FieldGuideMsg(field_guide.Msg)
}

pub fn init() -> Pages {
  Pages(
    start: start.init(),
    beam: beam.init(),
    otp: otp.init(),
    gleam: gleam_lang.init(),
    principles: principles.init(),
    atlas: atlas.init(),
    foundations: foundations.init(),
    outside_world: outside_world.init(),
    durable_work: durable_work.init(),
    agents: agents.init(),
    compose: compose.init(),
    field_guide: field_guide.init(),
  )
}

pub fn update(
  pages: Pages,
  msg: PageMsg,
  context: Context,
) -> #(Pages, Effect(PageMsg)) {
  case msg {
    StartMsg(msg) -> {
      let #(page, effect) = start.update(pages.start, msg, context)
      #(Pages(..pages, start: page), effect.map(effect, StartMsg))
    }
    BeamMsg(msg) -> {
      let #(page, effect) = beam.update(pages.beam, msg, context)
      #(Pages(..pages, beam: page), effect.map(effect, BeamMsg))
    }
    OtpMsg(msg) -> {
      let #(page, effect) = otp.update(pages.otp, msg, context)
      #(Pages(..pages, otp: page), effect.map(effect, OtpMsg))
    }
    GleamMsg(msg) -> {
      let #(page, effect) = gleam_lang.update(pages.gleam, msg, context)
      #(Pages(..pages, gleam: page), effect.map(effect, GleamMsg))
    }
    PrinciplesMsg(msg) -> {
      let #(page, effect) = principles.update(pages.principles, msg, context)
      #(Pages(..pages, principles: page), effect.map(effect, PrinciplesMsg))
    }
    AtlasMsg(msg) -> {
      let #(page, effect) = atlas.update(pages.atlas, msg, context)
      #(Pages(..pages, atlas: page), effect.map(effect, AtlasMsg))
    }
    FoundationsMsg(msg) -> {
      let #(page, effect) = foundations.update(pages.foundations, msg, context)
      #(Pages(..pages, foundations: page), effect.map(effect, FoundationsMsg))
    }
    OutsideWorldMsg(msg) -> {
      let #(page, effect) =
        outside_world.update(pages.outside_world, msg, context)
      #(
        Pages(..pages, outside_world: page),
        effect.map(effect, OutsideWorldMsg),
      )
    }
    DurableWorkMsg(msg) -> {
      let #(page, effect) =
        durable_work.update(pages.durable_work, msg, context)
      #(Pages(..pages, durable_work: page), effect.map(effect, DurableWorkMsg))
    }
    AgentsMsg(msg) -> {
      let #(page, effect) = agents.update(pages.agents, msg, context)
      #(Pages(..pages, agents: page), effect.map(effect, AgentsMsg))
    }
    ComposeMsg(msg) -> {
      let #(page, effect) = compose.update(pages.compose, msg, context)
      #(Pages(..pages, compose: page), effect.map(effect, ComposeMsg))
    }
    FieldGuideMsg(msg) -> {
      let #(page, effect) = field_guide.update(pages.field_guide, msg, context)
      #(Pages(..pages, field_guide: page), effect.map(effect, FieldGuideMsg))
    }
  }
}

pub fn view(pages: Pages, route: Route, context: Context) -> Element(PageMsg) {
  case route {
    route.CourseMap -> start.view(pages.start, context) |> element.map(StartMsg)
    route.Module(route.Beam) ->
      beam.view(pages.beam, context) |> element.map(BeamMsg)
    route.Module(route.Otp) ->
      otp.view(pages.otp, context) |> element.map(OtpMsg)
    route.Module(route.Gleam) ->
      gleam_lang.view(pages.gleam, context) |> element.map(GleamMsg)
    route.Module(route.Principles) ->
      principles.view(pages.principles, context) |> element.map(PrinciplesMsg)
    route.Module(route.Atlas) ->
      atlas.view(pages.atlas, context) |> element.map(AtlasMsg)
    route.Module(route.Foundations) ->
      foundations.view(pages.foundations, context)
      |> element.map(FoundationsMsg)
    route.Module(route.OutsideWorld) ->
      outside_world.view(pages.outside_world, context)
      |> element.map(OutsideWorldMsg)
    route.Module(route.DurableWork) ->
      durable_work.view(pages.durable_work, context)
      |> element.map(DurableWorkMsg)
    route.Module(route.Agents) ->
      agents.view(pages.agents, context) |> element.map(AgentsMsg)
    route.Module(route.Compose) ->
      compose.view(pages.compose, context) |> element.map(ComposeMsg)
    route.Module(route.FieldGuide) ->
      field_guide.view(pages.field_guide, context) |> element.map(FieldGuideMsg)
  }
}

/// The reader arrived on `route`, or turned motion back on while there. Only
/// pages that animate on arrival do anything.
pub fn enter(
  pages: Pages,
  route: Route,
  context: Context,
) -> #(Pages, Effect(PageMsg)) {
  case route {
    route.Module(route.Principles) -> {
      let #(page, effect) = principles.enter(pages.principles, context)
      #(Pages(..pages, principles: page), effect.map(effect, PrinciplesMsg))
    }
    _ -> #(pages, effect.none())
  }
}

/// The reader left `route`: pause its tours.
pub fn leave(pages: Pages, route: Route) -> Pages {
  case route {
    route.CourseMap -> Pages(..pages, start: start.leave(pages.start))
    route.Module(route.Beam) -> Pages(..pages, beam: beam.leave(pages.beam))
    route.Module(route.Otp) -> Pages(..pages, otp: otp.leave(pages.otp))
    route.Module(route.Gleam) ->
      Pages(..pages, gleam: gleam_lang.leave(pages.gleam))
    route.Module(route.Principles) ->
      Pages(..pages, principles: principles.leave(pages.principles))
    route.Module(route.Atlas) -> Pages(..pages, atlas: atlas.leave(pages.atlas))
    route.Module(route.Foundations) ->
      Pages(..pages, foundations: foundations.leave(pages.foundations))
    route.Module(route.OutsideWorld) ->
      Pages(..pages, outside_world: outside_world.leave(pages.outside_world))
    route.Module(route.DurableWork) ->
      Pages(..pages, durable_work: durable_work.leave(pages.durable_work))
    route.Module(route.Agents) ->
      Pages(..pages, agents: agents.leave(pages.agents))
    route.Module(route.Compose) ->
      Pages(..pages, compose: compose.leave(pages.compose))
    route.Module(route.FieldGuide) ->
      Pages(..pages, field_guide: field_guide.leave(pages.field_guide))
  }
}

/// Register every real-time widget component before the app starts.
pub fn register_components() -> Result(Nil, lustre.Error) {
  [
    beam.register(),
    otp.register(),
    gleam_lang.register(),
    principles.register(),
    atlas.register(),
    foundations.register(),
    outside_world.register(),
    durable_work.register(),
    agents.register(),
    compose.register(),
    field_guide.register(),
  ]
  |> list.try_each(fn(registered) { registered })
  |> result.map(fn(_) { Nil })
}
