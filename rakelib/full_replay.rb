# frozen_string_literal: true

# The environment variable `rake full` sets so the pipeline replay spec runs
# every recorded variant. The Rakefile and the specs share this one name.
module FullReplay
  ENV_VAR = "QUAACK_FULL_REPLAY"

  def self.on?(env = ENV) = env[ENV_VAR] == "1"
end
