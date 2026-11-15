import gleeunit
import moderation_desk/app

pub fn main() -> Nil {
  app.quiet()
  gleeunit.main()
}
