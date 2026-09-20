// THROWAWAY: Keep native exception values opaque at the Sinal boundary.
pub opaque type BeamException

pub type ExceptionClass {
  ErrorClass
  ExitClass
  ThrowClass
}

@external(erlang, "sinal_scope_ffi", "exception_class")
pub fn exception_class(exception: BeamException) -> ExceptionClass

@external(erlang, "sinal_scope_ffi", "reraise")
pub fn reraise(exception: BeamException) -> a
