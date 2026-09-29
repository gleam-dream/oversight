import gleam/http/request
import http_gun

pub fn invalid(client: http_gun.Client, req: request.Request(String)) {
  http_gun.send(client, req, http_gun.limits())
}
