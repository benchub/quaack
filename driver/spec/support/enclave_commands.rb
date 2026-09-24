# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

# Commands that run the enclave script in a child process, for the driver's
# local transport. They run the repo's enclave/exe/quaacks with `ruby -I`,
# the way enclave/spec/cli_spec.rb does, inside this bundle. The driver's
# spec process never loads the enclave gem itself: only the children do.
module EnclaveCommands
  ENCLAVE = File.join(REPO_ROOT, "enclave")
  RUBY = [RbConfig.ruby, "-I", File.join(ENCLAVE, "lib")].freeze

  module_function

  # The real `quaacks`, as a command for Transport::Local.
  def quaacks = [*RUBY, File.join(ENCLAVE, "exe", "quaacks")]

  # The enclave's VERSION, read in a child so this process doesn't load it.
  def enclave_version
    out, err, status = Open3.capture3(*RUBY, "-e", 'require "quaack/enclave/version"; print Quaack::Enclave::VERSION')
    raise "couldn't read the enclave version: #{err}" unless status.success?

    out
  end

  # A command that runs CLI.main, as exe/quaacks does, with one test step
  # plugged in as the subcommand "probe". body is Ruby run inside the step,
  # with the step's keyword arguments in `inputs`. step holds the Step's
  # other settings, such as input: true or options:. The script is written
  # into dir.
  def probe(dir, body, **step)
    script = File.join(dir, "probe-#{Dir.children(dir).size}.rb")
    File.write(script, <<~RUBY)
      require "json"
      require "quaack/enclave"
      cli = Quaack::Enclave::CLI
      handler = ->(**inputs) { #{body} }
      exit cli.main(ARGV, steps: { "probe" => cli::Step.new(handler:, **#{step.inspect}) })
    RUBY
    [*RUBY, script]
  end

  # A command that stands in for the enclave script entirely: it runs the
  # Ruby source, which prints whatever raw output a spec needs, including
  # output the real script never prints, such as a cut-off line.
  def raw(source) = [RbConfig.ruby, "-e", source]

  # A fake ssh executable, written into dir, standing in for ssh and the
  # jump server's shell. Like real ssh, it takes its options up to `--`, then
  # the host, then joins the rest of its arguments with spaces into one
  # string and hands that to the remote side's shell, here `sh -c`, with
  # remote_bin first on PATH. It records the arguments it was given, NUL
  # separated, in dir/ssh-argv.
  def fake_ssh(dir, remote_bin:)
    ssh = File.join(dir, "ssh")
    File.write(ssh, <<~SH)
      #!/bin/sh
      printf '%s\\0' "$@" > '#{dir}/ssh-argv'
      while [ "$#" -gt 0 ]; do arg=$1; shift; [ "$arg" = "--" ] && break; done
      shift
      PATH='#{remote_bin}':$PATH exec sh -c "$*"
    SH
    FileUtils.chmod(0o755, ssh)
    ssh
  end

  # What the fake ssh at dir was last given.
  def ssh_argv(dir) = File.read(File.join(dir, "ssh-argv")).split("\0")

  # Writes an executable `quaacks` into dir that runs command with its own
  # arguments, as the jump server's quaacks would.
  def remote_quaacks(dir, command)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "quaacks")
    File.write(path, "#!/bin/sh\nexec #{Shellwords.join(command)} \"$@\"\n")
    FileUtils.chmod(0o755, path)
    dir
  end
end
