import gleam/list
import gleam/string
import lustre/element
import pages/atlas
import pages/atlas/packages.{
  BuildsOn, Everything, Fabric, HttpGun, IsSelected, JsonBlueprint, LlmWire,
  Serving, Sinal, Unrelated, UsesIt,
}
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

// THE MAP ---------------------------------------------------------------------

pub fn the_map_holds_twelve_libraries_and_three_tools_test() {
  assert list.length(packages.packages) == 15
  assert list.length(packages.in_layer(packages.Tooling)) == 3
  let rows = list.map(packages.layers, packages.in_layer)
  assert list.flatten(rows) == packages.packages
}

pub fn eight_libraries_build_on_sinal_test() {
  assert list.length(packages.used_by(Sinal)) == 8
}

pub fn lower_layers_never_build_on_higher_ones_test() {
  let rank = fn(layer) {
    let assert Ok(#(_, index)) =
      packages.layers
      |> list.index_map(fn(l, i) { #(l, i) })
      |> list.find(fn(pair) { pair.0 == layer })
    index
  }
  list.each(packages.packages, fn(package) {
    let own = rank(packages.info(package).layer)
    list.each(packages.info(package).deps, fn(dep) {
      assert rank(packages.info(dep).layer) <= own
    })
  })
}

pub fn tiles_relate_to_the_selected_package_test() {
  assert packages.relation(Fabric, Fabric) == IsSelected
  assert packages.relation(Fabric, LlmWire) == BuildsOn
  assert packages.relation(LlmWire, Fabric) == UsesIt
  assert packages.relation(Fabric, packages.Retrace) == Unrelated
  assert packages.relation(Sinal, HttpGun) == UsesIt
}

pub fn a_need_selects_the_first_package_serving_it_test() {
  assert packages.first_serving(packages.CallModel) == Ok(JsonBlueprint)
  assert packages.first_serving(packages.SignIn) == Ok(packages.Hellhound)
  assert packages.serves(LlmWire, Serving(packages.CallModel))
  assert !packages.serves(Sinal, Serving(packages.CallModel))
  assert packages.serves(packages.Oversight, Everything)
}

pub fn every_need_has_a_package_test() {
  list.each(packages.needs, fn(need) {
    assert packages.first_serving(need) != Error(Nil)
  })
}

// THE TOUR --------------------------------------------------------------------

fn send(model: atlas.Model, command: tour.Command) -> atlas.Model {
  let context = context.new(motion.On, progress.empty())
  atlas.update(model, atlas.Tour(atlas.Map, command), context).0
}

pub fn the_atlas_tour_walks_the_map_test() {
  let model = atlas.init()
  assert model.selected == Fabric
  let model = send(model, tour.Next)
  assert model.selected == Sinal
  let model = send(model, tour.Next)
  assert model.selected == Fabric
  assert model.filter == Everything
  let model = send(model, tour.Next)
  // "Call an LLM" filters the map; JSON Blueprint is the first tile it keeps,
  // exactly as in the reference.
  assert model.filter == Serving(packages.CallModel)
  assert model.selected == JsonBlueprint
  let model = send(model, tour.Next)
  assert model.filter == Serving(packages.PersonDecides)
  assert model.selected == packages.Decisions
  let model = send(model, tour.Next)
  assert model.filter == Everything
  assert model.selected == packages.Decisions
  assert tour.phase(tour.get(model.tours, atlas.Map)) == Guided(5, Paused)
  let model = send(model, tour.Next)
  assert tour.phase(tour.get(model.tours, atlas.Map)) == Free
}

pub fn going_back_resets_the_map_test() {
  let model =
    atlas.init()
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Back)
  assert model.selected == Fabric
  assert model.filter == Everything
  let model = send(model, tour.Back) |> send(tour.Back)
  assert model.selected == Fabric
  assert tour.phase(tour.get(model.tours, atlas.Map)) == Guided(0, Paused)
}

pub fn the_atlas_tour_has_six_steps_test() {
  assert list.length(atlas.script(atlas.Map).steps) == 6
}

pub fn foundations_is_the_bottom_row_test() {
  let page =
    atlas.view(atlas.init(), context.new(motion.On, progress.empty()))
    |> element.to_string
  let position = fn(name) {
    let assert [before, _] = string.split(page, ">" <> name <> "</span>")
    string.length(before)
  }
  assert position("Tooling") < position("Inspection")
  assert position("Durable work") < position("Transport")
  assert position("Transport") < position("Foundations")
}

pub fn the_llm_step_names_what_the_filter_keeps_test() {
  let assert Ok(step) =
    atlas.script(atlas.Map).steps |> list.drop(3) |> list.first
  assert string.contains(step.text, "JSON Blueprint and LLM Wire")
  assert string.contains(step.text, "selects JSON Blueprint")
}
