# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../script/prompt_pack/run"

# Task 20260929-18: the pack's leak check scans every file the script
# writes, but not the LLM replies. A reply can't leak a sentinel that no
# prompt held, and models do invent dates that happen to match one.
RSpec.describe "PromptPack.leaks" do
  around do |example|
    Dir.mktmpdir("prompt-pack-leaks") do |dir|
      @corpus = dir
      example.run
    end
  end

  def plant(path, text)
    file = File.join(@corpus, "q", path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
  end

  let(:date) { PromptPack::MIN_QUANTITY_SINCE[0, 10] }

  it "ignores a sentinel date that a reply invents" do
    plant("llm-counterexamples-4/reply-claude-3.md", "dates 2024-02-07, #{date}, 2024-02-09")
    plant("llm-counterexamples-4/reply-gemini-1.md", "since #{date}")
    plant("llm-counterexamples-4/prompt.md", "no literals here")
    expect(PromptPack.leaks(@corpus)).to eq([])
  end

  %w[llm-counterexamples-4/prompt.md llm-counterexamples-4/chat.md stopped.md
     llm-counterexamples-4/notes.md llm-counterexamples-4/reply-claude-3.txt.md
     llm-counterexamples-4/my-reply-claude-3.md].each do |path|
    it "flags a sentinel planted in #{path}" do
      plant("llm-counterexamples-4/reply-claude-3.md", "nothing")
      plant(path, "where created_at >= '#{date}'")
      expect(PromptPack.leaks(@corpus).join("\n")).to include(date).and include(path)
    end
  end

  it "flags a full sentinel stamp in a prompt" do
    plant("llm-rewrites-1/prompt.md", "x #{PromptPack::SINCE} y")
    expect(PromptPack.leaks(@corpus).join("\n")).to include("llm-rewrites-1/prompt.md")
  end

  it "finds no sentinel in the committed pack" do
    expect(PromptPack.leaks).to eq([])
  end
end
