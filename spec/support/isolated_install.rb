# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# Installs one of the repo's gems, plus only its dependency closure, into a
# throwaway GEM_HOME, then runs its executable there, outside Bundler. Inside
# the bundle every process already has every gem's lib/ on $LOAD_PATH, so only
# a run like this shows what the gem really loads.
class IsolatedInstall
  GEM_COMMAND = File.join(RbConfig::CONFIG["bindir"], "gem")

  Run = Data.define(:stdout, :stderr, :status, :loaded_features)

  # `built_gem_names` are the gems built from a gemspec, the repo's own or one
  # in `sources`, rather than linked from the bundle.
  attr_reader :dir, :home, :gem_names, :built_gem_names

  # The script that records $LOADED_FEATURES. It shows up in them itself.
  def dumper = File.join(@dir, "dump_features.rb")

  # `gem_name` is a repo gem such as "quaacks". `closure` is the names
  # of everything it depends on. `sources` maps gem names to gemspecs to build
  # and install instead of the repo's own or the bundle's, such as a
  # throwaway copy of a repo gem.
  def initialize(gem_name, closure:, dir:, sources: {})
    @dir = dir
    @sources = sources
    @home = File.join(dir, "gem_home")
    @gem_names = [gem_name, *closure].uniq
    %w[gems specifications extensions].each { |d| FileUtils.mkdir_p(File.join(@home, d)) }
    @built_gem_names, other_gems = @gem_names.partition { |n| repo_gemspec(n) }
    other_gems.each { |n| link_installed(n) }
    install_repo_gems(@built_gem_names)
  end

  # Runs the executable `exe` with `args`. Records $LOADED_FEATURES at exit.
  def run(exe, *, **) = run_ruby(File.join(@home, "bin", exe), *, **)

  # Runs the Ruby script `script` with `args`, the same way as an executable.
  # `env` adds to the child's environment, such as a HOME, and `stdin` is
  # what it reads on stdin.
  def run_ruby(script, *, env: {}, stdin: "")
    features_file = File.join(@dir, "loaded_features.txt")
    FileUtils.rm_f(features_file)
    dumper = self.dumper
    File.write(dumper, "at_exit { File.write(ENV.fetch('QUAACK_FEATURES_OUT'), $LOADED_FEATURES.join(\"\\n\")) }\n")
    env = isolated_env.merge(env, "RUBYOPT" => "-r#{dumper}", "QUAACK_FEATURES_OUT" => features_file)
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby, script, *, stdin_data: stdin)
    end
    features = File.exist?(features_file) ? File.read(features_file).split("\n") : []
    Run.new(out, err, status, features)
  end

  # Maps each installed gem's name to where its files live, with symlinks
  # resolved, since Ruby records loaded features by their real path.
  def gem_dirs
    Dir.glob(File.join(@home, "specifications", "*.gemspec")).to_h do |path|
      spec = Gem::Specification.load(path)
      [spec.name, File.realpath(spec.full_gem_path)]
    end
  end

  private

  def isolated_env
    {
      "GEM_HOME" => @home, "GEM_PATH" => @home, "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil, "RUBYGEMS_GEMDEPS" => nil
    }
  end

  def repo_gemspec(name) = @sources[name] || RepoGems.gemspec_path_of(name)

  # Links an already-installed gem from the bundle, so native extensions
  # don't have to be rebuilt.
  def link_installed(name)
    spec = Gem::Specification.find_by_name(name)
    FileUtils.ln_s(spec.full_gem_path, File.join(@home, "gems", File.basename(spec.full_gem_path)))
    FileUtils.ln_s(spec.loaded_from, File.join(@home, "specifications", File.basename(spec.loaded_from)))
    link_extension(spec)
  end

  def link_extension(spec)
    return unless File.directory?(spec.extension_dir)

    target = File.join(@home, spec.extension_dir.delete_prefix("#{spec.base_dir}/"))
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.ln_s(spec.extension_dir, target)
  end

  def install_repo_gems(names)
    packages = names.map do |name|
      package = File.join(@dir, "#{name}.gem")
      gemspec = repo_gemspec(name)
      gem_command("build", File.basename(gemspec), "--output", package, chdir: File.dirname(gemspec))
      package
    end
    gem_command("install", "--local", "--ignore-dependencies", "--no-document", "--install-dir", @home, *packages)
  end

  def gem_command(*args, chdir: @dir)
    out, status = Bundler.with_unbundled_env do
      Open3.capture2e(isolated_env, RbConfig.ruby, GEM_COMMAND, *args, chdir: chdir)
    end
    raise "gem #{args.first} failed:\n#{out}" unless status.success?
  end
end
