# frozen_string_literal: true

# 固定 JSON 快照夹具。sebas-process 的选卡/依赖/证据判定都吃快照，
# 各测试文件原先各自复制一份 issue/automation/evidence 构造器，字段一改就
# 多处漂移；统一到这里，字段形态只有一处定义。
require "json"

module SnapshotHelpers
  # 工作包卡面：automation 块前放可选的前置依赖散文，供 prose↔automation 对账用例使用。
  def automation(kind: "work_package", order: [1], depends_on: [], external: [], prose: nil)
    prose_section = prose ? "\n## 前置依赖\n\n#{prose}\n" : ""
    body = <<~MD
      ## 目标
      测试
      #{prose_section}
      ```json automation
      #{" "}
      MD
    body.sub("#{" "}\n", "") + JSON.pretty_generate(
      {
        "schema" => 1,
        "kind" => kind,
        "order" => order,
        "depends_on" => depends_on,
        "external" => external
      }
    ) + "\n```\n"
  end

  def evidence(subject:, status: "accepted", ready: nil, merged: true, untested: [],
    gate_status: nil, evidence_path: nil, source: "maintainer")
    block = {
      "schema" => 1,
      "subject" => subject,
      "status" => status,
      "source" => source,
      "source_ref" => "https://github.com/o/r/issues/1#issuecomment-1",
      "pr" => 10,
      "merge_commit" => "abc123",
      "merged_into_main" => merged,
      "checks" => "https://ci/1",
      "gate_status" => gate_status,
      "evidence_path" => evidence_path,
      "untested" => untested,
      "ready" => ready
    }
    "```json evidence\n#{JSON.pretty_generate(block)}\n```\n"
  end

  def issue(number, body: "", labels: [], milestone: 2, state: "OPEN", state_reason: nil, blocked_by: [],
    status: nil, type: nil)
    {
      "number" => number,
      "title" => "issue #{number}",
      "state" => state,
      "state_reason" => state_reason,
      "body" => body,
      "labels" => labels,
      "milestone" => milestone,
      "assignees" => [],
      "blocked_by" => blocked_by,
      "status" => status,
      "type" => type
    }
  end

  def milestone(number:, order:, track:, open_issues: 0, state: "open")
    {
      "number" => number,
      "title" => "M#{order}",
      "state" => state,
      "order" => order,
      "track" => track,
      "open_issues" => open_issues,
      "description" => "order: #{order}\ntrack: #{track}\n"
    }
  end

  def snapshot(issues:, milestones: nil, pull_requests: [], maintainers: ["ShiningRay"],
    source_authors: nil, gates: {}, externals: {}, trusted_bots: [], source_bodies: {})
    {
      "repo" => "o/r",
      "main_sha" => "deadbeef",
      "milestones" => milestones || [
        milestone(number: 2, order: "4", track: "main", open_issues: issues.length),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 5)
      ],
      "issues" => issues,
      "pull_requests" => pull_requests,
      "maintainers" => maintainers,
      "source_authors" => source_authors || {
        "https://github.com/o/r/issues/1#issuecomment-1" => "ShiningRay"
      },
      "gates" => gates,
      "externals" => externals,
      "trusted_bots" => trusted_bots,
      "source_bodies" => source_bodies
    }
  end

  def select(data, record: nil)
    SebasAgents::Policy::Selection.select_action(SebasAgents::Model::Snapshot.from_hash(data), record: record)
  end
end
