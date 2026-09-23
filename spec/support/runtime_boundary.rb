# frozen_string_literal: true

require "rbconfig"

# The runtime half of the boundary check. spec/runtime_boundary_spec.rb runs
# it on the real gems, and spec/runtime_boundary_checker_spec.rb runs it on
# throwaway copies with planted violations.
#
# It builds one side's gem, installs it with its gemspec's dependency closure
# into a throwaway GEM_HOME, and runs it there, outside Bundler, three ways:
# with --version, with no arguments (the usage branch), and with a script
# that requires every .rb file under the lib/ of each installed gem built
# from the repo, such as quaacks and quaack-protocol. Each run must
# exit as expected, and every file it loads must pass two checks:
#
# - It comes from the standard library, the side's own gem, or an allowed
#   gem. For the enclave, the allowed gems are Boundary::ENCLAVE_ALLOWED_GEMS,
#   the reviewed allowlist, not what the gemspec says. The driver has no
#   allowlist, so its allowed gems are its gemspec's closure.
# - It isn't forbidden to that side, even if the allowlist admits it. A file
#   is forbidden if it's in the other side's installed gem, or if its path
#   after its last lib/ segment is one of the side's forbidden requires, such as
#   quaack/driver or openai. That last test catches an LLM SDK by what it
#   loads as, whatever its gem is called.
#
# It guards against honest mistakes, such as a dependency that shouldn't be
# there or a plain require of the other side's code. Deliberate evasion is
# out of scope by design: anyone who can run the enclave script can move data
# in easier ways. So it doesn't try to catch hidden requires, such as one
# built at runtime from data or reached through send or eval, or code that
# edits $LOADED_FEATURES or turns off the check.
#
# It also can't see code that never runs. A require inside a method body
# that none of the three runs calls loads nothing, and files outside lib/,
# other than the executable, aren't required. The static checks in
# boundary_spec.rb catch plain requires there.
#
# And it can't see a require that fails and is rescued, such as
# `begin; require "openai"; rescue LoadError; end`. The side's install
# doesn't have the gem, so nothing loads and the run exits cleanly, but the
# code would load it wherever the gem is installed. Only the static check
# catches that.
module RuntimeBoundary
  EVERY_LIB_FILE = "every file under lib/"

  # Each set of executable arguments to run, and the exit status it must end
  # with. 64 is EX_USAGE, what both CLIs return for bad arguments.
  COMMANDS = { ["--version"] => 0, [] => 64 }.freeze

  # Activates each gem named in its arguments and requires every .rb file
  # under its lib/, in a fixed order.
  REQUIRE_EVERY_LIB_FILE = <<~RUBY
    ARGV.each { |name| gem name }
    ARGV.each do |name|
      lib = File.join(Gem.loaded_specs.fetch(name).full_gem_path, "lib")
      Dir.glob("**/*.rb", base: lib).sort.each { |file| require File.join(lib, file) }
    end
  RUBY

  # One side of the boundary. `gemspec_path` is the gemspec to build, the
  # repo's own or a throwaway copy's. `sources` maps other gem names to
  # gemspecs to build instead of taking them from the repo or the bundle.
  # `allowed_gems` is nil to allow the gemspec's closure.
  Side = Data.define(:gemspec_path, :exe, :sources, :allowed_gems, :forbidden_gems, :forbidden_requires)

  Violation = Data.define(:run, :message) do
    def to_s = "#{run}: #{message}"
  end

  # `runs` maps each run's label, such as "quaacks --version", to its
  # IsolatedInstall::Run.
  Report = Data.define(:install, :runs, :violations)

  module_function

  def enclave(gemspec_path: RepoGems.gemspec_path("enclave"), sources: {}, allowed_gems: Boundary::ENCLAVE_ALLOWED_GEMS)
    Side.new(gemspec_path: gemspec_path, exe: "quaacks", sources: sources, allowed_gems: allowed_gems,
             forbidden_gems: [RepoGems.gemspec("driver").name],
             forbidden_requires: Boundary::ENCLAVE_FORBIDDEN_REQUIRES)
  end

  # The driver needs no forbidden requires: the enclave isn't an allowed gem,
  # and the check forbids its installed gem even when the gemspec pulls it in.
  def driver(gemspec_path: RepoGems.gemspec_path("driver"), sources: {})
    Side.new(gemspec_path: gemspec_path, exe: "quaack", sources: sources, allowed_gems: nil,
             forbidden_gems: [RepoGems.gemspec("enclave").name],
             forbidden_requires: [])
  end

  # Installs `side` into `dir`, runs it every way, and returns a Report.
  def check(side, dir:) = Check.new(side, dir).report

  # Loading a copy's gemspec loads the copy's version file too, which
  # redefines the real gem's VERSION constant and warns.
  def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  # rubyarchdir sits inside rubylibdir on Homebrew's Ruby, but not on every
  # build. Debian's, for one, keeps it under /usr/lib/<multiarch>/ruby/.
  def stdlib_dirs
    [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"]].map { |d| File.realpath(d) }
  end

  # One run of the check on one side.
  class Check
    def initialize(side, dir)
      @side = side
      @spec = RuntimeBoundary.quietly { RepoGems.load(side.gemspec_path) }
      @sources = { @spec.name => side.gemspec_path, **side.sources }
      @closure = closure
      @install = IsolatedInstall.new(@spec.name, closure: @closure, dir: dir, sources: @sources)
    end

    def report
      runs = self.runs
      rules = self.rules
      violations = runs.flat_map { |label, (run, status)| rules.run_violations(label, run, status) }
      Report.new(install: @install, runs: runs.transform_values(&:first), violations: violations)
    end

    private

    # The side's own dependencies come from its gemspec, which may be a copy,
    # so a dependency added to that copy counts. Every other gem's come from
    # the bundle's gem of that name, even if `sources` has a copy of it, so a
    # dependency added to a protocol copy is ignored. That's fine: the gem it
    # names isn't installed, so a require of it still exits 1. A gem the
    # bundle lacks still counts, just with no dependencies of its own.
    def closure = Boundary.dependency_closure(@spec).names

    # Maps each run's label to the run and the exit status it must end with.
    def runs
      runs = COMMANDS.to_h do |args, status|
        [[@side.exe, *args].join(" "), [@install.run(@side.exe, *args), status]]
      end
      script = File.join(@install.dir, "require_every_lib_file.rb")
      File.write(script, REQUIRE_EVERY_LIB_FILE)
      # Every gem built from the repo ships with the side, such as
      # quaack-protocol, so their files get required too.
      runs.merge(EVERY_LIB_FILE => [@install.run_ruby(script, *@install.built_gem_names), 0])
    end

    def rules
      gem_dirs = @install.gem_dirs
      allowed = [@spec.name, *(@side.allowed_gems || @closure)]
      Rules.new(dumper: @install.dumper,
                allowed_dirs: [*RuntimeBoundary.stdlib_dirs, *gem_dirs.values_at(*allowed).compact],
                forbidden_dirs: gem_dirs.values_at(*@side.forbidden_gems).compact,
                forbidden_requires: @side.forbidden_requires)
    end
  end

  # What one side may and mustn't load. The dirs are real paths.
  Rules = Data.define(:dumper, :allowed_dirs, :forbidden_dirs, :forbidden_requires) do
    def run_violations(label, run, status)
      violations = []
      unless run.status.exitstatus == status
        violations << Violation.new(label, "exited #{run.status.exitstatus}, not #{status}; stderr was #{run.stderr}")
      end
      return violations << Violation.new(label, "recorded no loaded files") if run.loaded_features.empty?

      violations + run.loaded_features.flat_map { |feature| feature_violations(label, feature) }
    end

    private

    def feature_violations(label, feature)
      return [] if !feature.include?("/") || feature == dumper

      problems = []
      problems << "isn't from the standard library or an allowed gem" unless under?(feature, allowed_dirs)
      problems << "this side must never load" if under?(feature, forbidden_dirs) || forbidden_require?(feature)
      problems.map { |problem| Violation.new(label, "loaded #{feature}, which #{problem}") }
    end

    def under?(path, dirs) = dirs.any? { |dir| path.start_with?("#{dir}/") }

    # Whether the path after its last lib/ segment is a forbidden require, the
    # way the load path would see it.
    def forbidden_require?(path) = Boundary.forbidden_match(path.rpartition("/lib/").last, forbidden_requires)
  end
end
