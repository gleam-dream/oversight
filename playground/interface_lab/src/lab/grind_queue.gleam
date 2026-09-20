// THROWAWAY: Can local queue configuration express pause and capacity safely?
import lab/grind

pub opaque type LocalConcurrency {
  LocalConcurrency(Int)
}

pub opaque type ActiveCount {
  ActiveCount(Int)
}

pub type QueueConfigurationError {
  LocalConcurrencyMustBePositive
  ActiveCountMustNotBeNegative
  DuplicateQueueRoute(route: grind.QueueRoute)
}

pub fn local_concurrency(
  value: Int,
) -> Result(LocalConcurrency, QueueConfigurationError) {
  case value > 0 {
    True -> Ok(LocalConcurrency(value))
    False -> Error(LocalConcurrencyMustBePositive)
  }
}

pub fn active_count(
  value: Int,
) -> Result(ActiveCount, QueueConfigurationError) {
  case value >= 0 {
    True -> Ok(ActiveCount(value))
    False -> Error(ActiveCountMustNotBeNegative)
  }
}

pub type ProcessingMode {
  Processing
  Paused
}

// Route and concurrency already carry their own validated types. The public
// product lets a caller pause or rescale one route with a record update.
pub type QueueConfig {
  QueueConfig(
    route: grind.QueueRoute,
    concurrency: LocalConcurrency,
    mode: ProcessingMode,
  )
}

pub opaque type QueueConfigs {
  QueueConfigs(List(QueueConfig))
}

pub type QueueConfigLookup {
  ConfigFound(QueueConfig)
  ConfigMissing
}

pub fn queue_configs(
  configs: List(QueueConfig),
) -> Result(QueueConfigs, QueueConfigurationError) {
  case first_duplicate_route(configs) {
    Ok(route) -> Error(DuplicateQueueRoute(route))
    Error(Nil) -> Ok(QueueConfigs(configs))
  }
}

pub fn config_for_route(
  configs: QueueConfigs,
  route: grind.QueueRoute,
) -> QueueConfigLookup {
  let QueueConfigs(config_list) = configs
  find_config(config_list, route)
}

pub type DispatchPlan {
  DispatchPaused
  AtCapacity
  MayClaim(up_to: Int)
}

// This is an advisory count for one local processor. It neither reserves nor
// claims work, and it does not impose a cluster-wide concurrency limit.
// Pausing blocks new claim proposals only; admission and running attempts keep
// their existing behavior. A reduced limit takes effect as attempts finish.
pub fn plan_dispatch(config: QueueConfig, active: ActiveCount) -> DispatchPlan {
  let QueueConfig(concurrency: LocalConcurrency(limit), mode: mode, ..) = config
  let ActiveCount(active_value) = active
  case mode {
    Paused -> DispatchPaused
    Processing -> {
      let remaining = limit - active_value
      case remaining > 0 {
        True -> MayClaim(remaining)
        False -> AtCapacity
      }
    }
  }
}

fn first_duplicate_route(
  configs: List(QueueConfig),
) -> Result(grind.QueueRoute, Nil) {
  case configs {
    [] -> Error(Nil)
    [QueueConfig(route: route, ..), ..rest] ->
      case contains_route(route, rest) {
        True -> Ok(route)
        False -> first_duplicate_route(rest)
      }
  }
}

fn contains_route(route: grind.QueueRoute, configs: List(QueueConfig)) -> Bool {
  case configs {
    [] -> False
    [QueueConfig(route: candidate, ..), ..rest] ->
      case grind.same_queue_route(route, candidate) {
        True -> True
        False -> contains_route(route, rest)
      }
  }
}

fn find_config(
  configs: List(QueueConfig),
  route: grind.QueueRoute,
) -> QueueConfigLookup {
  case configs {
    [] -> ConfigMissing
    [
      QueueConfig(route: candidate, concurrency: concurrency, mode: mode),
      ..rest
    ] ->
      case grind.same_queue_route(route, candidate) {
        True -> ConfigFound(QueueConfig(candidate, concurrency, mode))
        False -> find_config(rest, route)
      }
  }
}
