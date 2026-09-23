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

  attr_reader :dir, :home, :gem_names

  # The script that records $LOADED_FEATURES. It shows up in them itself.
  def dumper = File.join(@dir, "dump_features.rb")

  # `gem_name` is a repo gem such as "quaack-enclave". `closure` is the names
  # of everything it depends on.
  def initialize(gem_name, closure:, dir:)
    @dir = dir
    @home = File.join(dir, "gem_home")
    @gem_names = [gem_name, *closure].uniq
    %w[gems specifications extensions].each { |d| FileUtils.mkdir_p(File.join(@home, d)) }
    repo_gems, other_gems = @gem_names.partition { |n| repo_gem_dir(n) }
    other_gems.each { |n| link_installed(n) }
    install_repo_gems(repo_gems)
  end

  # Runs the executable `exe` with `args`. Records $LOADED_FEATURES at exit.
  def run(exe, *)
    features_file = File.join(@dir, "loaded_features.txt")
    FileUtils.rm_f(features_file)
    dumper = self.dumper
    File.write(dumper, "at_exit { File.write(ENV.fetch('QUAACK_FEATURES_OUT'), $LOADED_FEATURES.join(\"\\n\")) }\n")
    env = isolated_env.merge("RUBYOPT" => "-r#{dumper}", "QUAACK_FEATURES_OUT" => features_file)
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, RbConfig.ruby, File.join(@home, "bin", exe), *)
    end
    features = File.exist?(features_file) ? File.read(features_file).split("\n") : []
    Run.new(out, err, status, features)
  end

  # Where each installed gem's files live, with symlinks resolved, since
  # Ruby records loaded features by their real path.
  def installed_gem_dirs
    Dir.glob(File.join(@home, "gems", "*")).map { |d| File.realpath(d) }
  end

  private

  def isolated_env
    {
      "GEM_HOME" => @home, "GEM_PATH" => @home, "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil
    }
  end

  def repo_gem_dir(name)
    dir = File.join(REPO_ROOT, name.delete_prefix("quaack-"))
    name.start_with?("quaack-") && File.exist?(File.join(dir, "#{name}.gemspec")) ? dir : nil
  end

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
      gem_command("build", "#{name}.gemspec", "--output", package, chdir: repo_gem_dir(name))
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
