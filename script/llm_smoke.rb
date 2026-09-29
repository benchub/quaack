# frozen_string_literal: true

# A live smoke test of the driver's LLM client against a real provider. It
# makes real API calls, which cost money, so it's opt-in and not part of
# `rake`:
#
#   QUAACK_ALLOW_REAL_LLM=1 PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec ruby script/llm_smoke.rb
#
# It uses the llm block of ~/.quaack/driver.json and its environment
# overrides, exactly as `quaack run` does, so it checks the setup README.md
# describes, for any provider. For example, for Groq:
#
#   QUAACK_ALLOW_REAL_LLM=1 QUAACK_LLM_PROVIDER=openai_compatible \
#     QUAACK_LLM_BASE_URL=https://api.groq.com/openai/v1 QUAACK_MODEL=llama-3.3-70b-versatile \
#     GROQ_API_KEY=... bundle exec ruby script/llm_smoke.rb
#
# (With the provider only in variables, api_key_env can't be set, so the key
# is read from OPENAI_API_KEY unless driver.json names another variable.)
#
# It asks for one text reply and one JSON reply that must match a schema,
# and prints the answers and the burndown's count of calls.

require "bundler/setup"
require "quaack/driver/burndown"
require "quaack/driver/driver_config"
require "quaack/driver/llm"

abort "Set QUAACK_ALLOW_REAL_LLM=1: this makes real, billed API calls." unless ENV["QUAACK_ALLOW_REAL_LLM"] == "1"

llm = Quaack::Driver::LLM
config = Quaack::Driver::DriverConfig.read(Dir.home) || {}
settings = llm.settings(config[llm::BLOCK])
burndown = Quaack::Driver::Burndown.new
client = llm::Client.new(burndown:, settings:)
puts "provider #{settings.provider}, model #{settings.model}, base_url #{settings.base_url || "(default)"}"

text = client.ask(step: "5a-5", system: "Answer in one short line.",
                  messages: [{ role: "user", content: "Name one PostgreSQL index type." }], max_tokens: 200)
puts "text: #{text}"

schema = { type: "object", properties: { indexes: { type: "array", items: { type: "string" } } },
           required: ["indexes"], additionalProperties: false }
json = client.ask(step: "5a-5", system: "You propose PostgreSQL indexes.", schema:, max_tokens: 500,
                  messages: [{ role: "user", content: "Propose one index for: SELECT * FROM t WHERE a = $1" }])
puts "json: #{json}"
puts "calls: #{burndown.llm_calls}"
