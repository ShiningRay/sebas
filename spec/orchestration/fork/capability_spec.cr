require "spec"
require "file_utils"
require "../../../src/platform/store/store"
require "../../../src/orchestration/fork/capability"
require "../../../src/providers/providers"
require "../../../src/orchestration/fork/snapshot_builder"

module Sebas
  describe "Capability 能力衰减（M4.2-WP1，semantics §5）" do
    it "未声明 tools → 默认只读档，无剔除项" do
      grant = ::Sebas::Orchestration::Fork::Capability.resolve(nil, ["*"])
      grant.effective.should eq(%w[memory.search session.read])
      grant.removed.should be_empty
    end

    it "声明 ∩ 父 allow 交集生效，白名单外剔除并回执列明" do
      grant = ::Sebas::Orchestration::Fork::Capability.resolve(
        %w[memory.search message.send file.write], %w[memory.search message.send]
      )
      grant.effective.should eq(%w[memory.search message.send])
      grant.removed.should eq(%w[file.write])
    end

    it "父 allow=[*] 现状口径 → 声明全集生效" do
      grant = ::Sebas::Orchestration::Fork::Capability.resolve(
        %w[memory.search message.send], ["*"]
      )
      grant.effective.should eq(%w[memory.search message.send])
      grant.removed.should be_empty
    end

    it "默认只读档不含写副作用工具（message.send / memory.save）" do
      grant = ::Sebas::Orchestration::Fork::Capability.resolve(nil, ["*"])
      grant.effective.includes?("message.send").should be_false
      grant.effective.includes?("memory.save").should be_false
    end
  end

  describe "SnapshotBuilder 工具清单注入（M4.2-WP1 §5.2 可观测）" do
    it "grant 非空时 system prompt 列生效工具集" do
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "t", count: 1, window: nil, include: nil,
        tools: %w[memory.search], role: nil, mode: "all", deadline: 3600
      )
      grant = ::Sebas::Orchestration::Fork::Capability.resolve(input.tools, ["*"])
      messages = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        [] of ::Sebas::Platform::Store::TranscriptRow, "", "", input, 1, grant
      )
      system = messages.first.content
      system.should contain("Available tools: memory.search")
    end

    it "grant 为空时不注入工具清单（M4.1 行为不变）" do
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "t", count: 1, window: nil, include: nil,
        tools: nil, role: nil, mode: "all", deadline: 3600
      )
      messages = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        [] of ::Sebas::Platform::Store::TranscriptRow, "", "", input, 1
      )
      messages.first.content.should_not contain("Available tools")
    end
  end
end
