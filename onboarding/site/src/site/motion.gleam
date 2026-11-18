//// Whether the site animates. It starts from the operating system's
//// reduced-motion setting; once the reader chooses, the choice is remembered.

pub type Motion {
  On
  Off
}

pub const storage_key = "gd-onboarding-motion-v1"

/// The motion to start with: a remembered choice wins over the system setting.
pub fn initial(stored: Result(String, Nil), system_reduces: Bool) -> Motion {
  case stored, system_reduces {
    Ok("on"), _ -> On
    Ok("off"), _ -> Off
    _, True -> Off
    _, False -> On
  }
}

pub fn toggle(motion: Motion) -> Motion {
  case motion {
    On -> Off
    Off -> On
  }
}

pub fn encode(motion: Motion) -> String {
  case motion {
    On -> "on"
    Off -> "off"
  }
}

pub fn is_on(motion: Motion) -> Bool {
  motion == On
}
