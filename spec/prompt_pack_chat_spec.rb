# frozen_string_literal: true

require_relative "../script/prompt_pack/run"

RSpec.describe "PromptPack.chat" do
  def ask(messages)
    Struct.new(:step, :body).new("llm-index-ideas", { system: "SYS-TEXT", messages:,
                                                      output_config: { format: { schema: { "type" => "object" } } } })
  end

  it "folds a multi-turn transcript into the system text and one quoting message" do
    chat = PromptPack.chat(ask([{ role: "user", content: "FIRST-ASK" },
                                { role: "assistant", content: [{ type: "text", text: "PLANTED-REPLY" }] },
                                { role: "user", content: "FOLLOW-UP" }]))
    expect(chat.scan(/^# (\w[\w ]*)$/).flatten).to eq(["System", "Message", "Reply format"])
    expect(chat).to include("# System\n\nSYS-TEXT\n")
    body = chat[/# Message\n\n(.*)\n# Reply format/m, 1]
    expect(body).to match(/Earlier in this conversation you were asked the following.*Treat that reply as your own/m)
    expect(body.index("FIRST-ASK")).to be < body.index("PLANTED-REPLY")
    expect(body.index("PLANTED-REPLY")).to be < body.index("FOLLOW-UP")
    expect(chat).to end_with(PromptPack.prompt(ask([{ role: "user", content: "x" }]))[/# Reply format.*/m])
  end

  it "writes no chat version of a single-turn prompt" do
    expect(PromptPack.chat(ask([{ role: "user", content: "ONLY" }]))).to be_nil
  end
end
