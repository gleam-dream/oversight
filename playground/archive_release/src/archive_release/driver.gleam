import archive_release/archive.{type Context}
import archive_release/domain.{type Release, Release}
import fabric/agent
import fabric/approvers
import fabric/model
import fabric/policy
import fabric/run
import fabric/tool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import json/blueprint/codec

pub fn definition() -> tool.Definition(Release, Release) {
  tool.define(
    "release_archive",
    "Release exactly one classified revision",
    domain.release_codec(),
    domain.release_codec(),
  )
}

/// Script selects one tool for the admitted revision; it never decides permission.
pub fn build(
  document: domain.Document,
  requester: domain.Principal,
  approvers: approvers.Approvers(String),
) -> agent.Agent(Context, String) {
  let assert Ok(arguments) =
    codec.encode_json(
      domain.release_codec(),
      Release(document.id, document.revision, requester),
    )
  let scripted =
    model.new(fn(request: model.Request) {
      case
        list.find_map(request.messages, fn(message) {
          case message {
            model.ToolResultMessage(_, content) -> Ok(content)
            _ -> Error(Nil)
          }
        })
      {
        Ok(content) -> Ok(model.FinalAnswer(content, None))
        Error(Nil) ->
          Ok(model.ToolRequest(
            model.AssistantTurn(
              "",
              [model.tool_call("release-1", "release_archive", arguments)],
              None,
            ),
            None,
          ))
      }
    })
  let release =
    tool.bind(
      definition(),
      fn(context, _call, input) { archive.release(context, input) },
      fn(error) {
        case error {
          archive.CurrentStateRefused ->
            tool.Explain("current archive state refused release")
          archive.Database(_) ->
            tool.Uncertain("database outcome requires application readback")
        }
      },
    )
  let assert Ok(agent) =
    agent.new("archive_release", scripted, [release], authorize)
    |> agent.with_version(2)
    |> agent.with_approvers(approvers)
    |> agent.with_max_turns(2)
    |> agent.build
  agent
}

fn authorize(
  context: Context,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  use input <- result.try(tool.input(definition(), action))
  case input {
    None -> Ok(policy.Deny("unknown archive action"))
    Some(release) ->
      case
        release.requester == context.principal,
        release.document == context.document.id
        && release.revision == context.document.revision,
        context.permission
      {
        False, _, _ -> Ok(policy.Deny("requester identity changed"))
        _, False, _ -> Ok(policy.Deny("stale document revision"))
        _, _, False -> Ok(policy.Deny("current permission revoked"))
        True, True, True ->
          case context.approval_policy, context.document.classification {
            domain.EmbargoOnly, domain.Public -> Ok(policy.Allow)
            _, _ ->
              Ok(policy.RequireApproval(run.Requirement("archive-review", 1)))
          }
      }
  }
}
