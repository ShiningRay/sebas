require "spec"
require "../../src/providers/tool_call_parser"
require "../../src/providers/fake_provider"

module Sebas
  describe "ToolCallParser（M4.3-WP1 ReAct 协议）" do
    it "JSON 块含 tool/args → 解析出调用" do
      text = <<-TEXT
        thinking...
        ```json
        {"tool": "memory.search", "args": {"query": "sebas"}}
        ```
        TEXT
      call = ::Sebas::Providers::ToolCallParser.parse(text)
      call.should be_a(::Sebas::Providers::ToolCallParser::Call)
      call = call.as(::Sebas::Providers::ToolCallParser::Call)
      call.tool.should eq("memory.search")
      call.args["query"].as_s.should eq("sebas")
    end

    it "无 JSON 块 / 非法 JSON / 缺 tool / tool 空串 → nil（终答）" do
      ::Sebas::Providers::ToolCallParser.parse("plain final answer").should be_nil
      ::Sebas::Providers::ToolCallParser.parse("```json\n{broken\n```").should be_nil
      ::Sebas::Providers::ToolCallParser.parse("```json\n{\"args\": {}}\n```").should be_nil
      ::Sebas::Providers::ToolCallParser.parse("```json\n{\"tool\": \"\", \"args\": {}}\n```").should be_nil
    end

    it "args 字符串含 } 与 ``` 序列不提前截断（CVnJ 回归）" do
      text = <<-TEXT
        ```json
        {"tool": "memory.save", "args": {"key": "k", "body": "} ```"}}
        ```
        TEXT
      call = ::Sebas::Providers::ToolCallParser.parse(text)
      call.should be_a(::Sebas::Providers::ToolCallParser::Call)
      call = call.as(::Sebas::Providers::ToolCallParser::Call)
      call.tool.should eq("memory.save")
      call.args["body"].as_s.should eq("} ```")
    end

    it "args 缺省 → 空对象（合法）" do
      text = <<-TEXT
        ```json
        {"tool": "session.read"}
        ```
        TEXT
      call = ::Sebas::Providers::ToolCallParser.parse(text)
      call.should be_a(::Sebas::Providers::ToolCallParser::Call)
      call = call.as(::Sebas::Providers::ToolCallParser::Call)
      call.args.as_h.should be_empty
    end
  end
end
