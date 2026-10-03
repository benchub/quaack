# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "error"

module Quaack
  module Driver
    module LLM
      # A local Copilot CLI command, behind Client. Each ask writes the
      # provider-neutral prompt to a private file, runs the configured argv
      # template without a shell, and reads the reply from stdout.
      class CopilotCLIAdapter # rubocop:disable Metrics/ClassLength
        DEFAULT_TIMEOUT = 600
        PROMPT_FILE = "prompt.md"
        PROMPT_PLACEHOLDER = "{prompt_file}"
        PROMPT_DIR_PLACEHOLDER = "{prompt_dir}"
        MODEL_PLACEHOLDER = "{model}"
        CUSTOM_INSTRUCTIONS_ENV = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        TASK_WAIT_ENV = "COPILOT_TASK_WAIT_TIMEOUT_SECONDS"
        STDERR_TAIL_LINES = 20

        DEFAULT_TEMPLATE = [
          "copilot",
          "--disable-builtin-mcps",
          "--no-ask-user",
          "--no-custom-instructions",
          "--available-tools=view",
          "--allow-tool=read({prompt_dir})",
          "--deny-tool=shell",
          "--deny-tool=write",
          "--deny-tool=url",
          "--model={model}",
          "-s",
          "-p",
          "Please follow my prompt in {prompt_file}. Reply only with the answer."
        ].freeze

        def initialize(settings:, **)
          @model = settings.model
          @template = settings.command_template || DEFAULT_TEMPLATE
          @timeout = settings.timeout_seconds || DEFAULT_TIMEOUT
        end

        def enforces_schema? = false

        def reply(step:, system:, messages:, max_tokens:, schema:, count:) # rubocop:disable Metrics/ParameterLists
          count.call
          Dir.mktmpdir("quaack-copilot-cli") do |dir|
            prompt_file = File.join(dir, PROMPT_FILE)
            write_prompt(prompt_file, prompt_text(step, system, messages, schema, max_tokens))
            run(template(prompt_file, dir), dir)
          end
        end

        private

        def write_prompt(path, prompt)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(prompt)
          end
        end

        def prompt_text(step, system, messages, schema, max_tokens)
          parts = ["Step: #{step}"]
          parts << "System prompt:\n#{system}" if system
          parts << "JSON schema:\n#{JSON.pretty_generate(schema)}" if schema
          parts << "Maximum reply tokens: #{max_tokens}"
          parts << "Conversation:\n#{messages.map { |m| "[#{m.fetch(:role)}]\n#{m.fetch(:content)}" }.join("\n\n")}"
          parts.join("\n\n")
        end

        def template(prompt_file, dir)
          @template.map do |arg|
            arg.gsub(PROMPT_PLACEHOLDER, prompt_file)
               .gsub(PROMPT_DIR_PLACEHOLDER, dir)
               .gsub(MODEL_PLACEHOLDER, @model)
          end
        end

        def run(argv, dir)
          result = spawn_and_capture(argv, dir)
          raise result.error if result.error
          return result.stdout unless result.stdout.empty?

          raise Error.new("llm_bad_response", "the copilot_cli command printed no reply")
        end

        Result = Data.define(:stdout, :stderr, :status, :error)

        def spawn_and_capture(argv, dir)
          with_pipes do |out_r, out_w, err_r, err_w|
            pid = spawn_process(argv, dir, out_w, err_w)
            readers = readers(out_r, out_w, err_r, err_w)
            status = wait(pid, @timeout)
            result_for(status, readers)
          end
        rescue Errno::ENOENT
          Result.new(stdout: "", stderr: "", status: nil,
                     error: Error.new("llm_unavailable", "the copilot_cli command couldn't be found"))
        end

        def with_pipes
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          yield(out_r, out_w, err_r, err_w)
        ensure
          [out_w, err_w, out_r, err_r].each { close_quietly(it) if it }
        end

        def readers(out_r, out_w, err_r, err_w)
          out_w.close
          err_w.close
          [Thread.new { out_r.read }, Thread.new { err_r.read }]
        end

        def result_for(status, readers)
          stdout = readers.first.value
          stderr = readers.last.value
          Result.new(stdout:, stderr:, status:, error: error_for(status, stderr))
        end

        def spawn_process(argv, dir, out_w, err_w)
          env = { CUSTOM_INSTRUCTIONS_ENV => nil, TASK_WAIT_ENV => @timeout.ceil.to_s }
          Process.spawn(env, *argv, chdir: dir, in: File::NULL, out: out_w, err: err_w, pgroup: true)
        end

        def wait(pid, timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            waited, status = Process.waitpid2(pid, Process::WNOHANG)
            return status if waited
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.01
          end
          kill_group(pid)
          _, status = Process.waitpid2(pid)
          TimeoutStatus.new(status)
        end

        TimeoutStatus = Data.define(:status) do
          def exitstatus = status.exitstatus
          def success? = false
          def timed_out? = true
        end

        def kill_group(pid)
          Process.kill("TERM", -pid)
          sleep 0.05
          Process.kill("KILL", -pid)
        rescue Errno::EPERM
          Process.kill("TERM", pid)
          sleep 0.05
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end

        def error_for(status, stderr)
          return Error.new("llm_unavailable", "the copilot_cli command timed out") if status.respond_to?(:timed_out?)
          return if status.success?

          rule = login_failure?(stderr) ? "llm_auth" : "llm_unavailable"
          Error.new(rule, "copilot_cli exited with status #{status.exitstatus}#{stderr_tail(stderr)}")
        end

        def login_failure?(stderr)
          stderr.match?(/(?:not logged in|not authenticated|login required|must log in|authentication required)/i)
        end

        def stderr_tail(stderr)
          return "" if stderr.empty?

          tail = stderr.lines.last(STDERR_TAIL_LINES).join.strip
          tail.empty? ? "" : ": #{tail}"
        end

        def close_quietly(io)
          io.close unless io.closed?
        rescue IOError
          nil
        end
      end
    end
  end
end
