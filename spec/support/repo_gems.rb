# frozen_string_literal: true

# The repo's own gems, found by their gemspecs. A gem's name doesn't follow
# from its directory: enclave/ holds the quaacks gem, and driver/ holds
# quaack-driver. So nothing here guesses one from the other.
module RepoGems
  module_function

  # The one gemspec in the repo directory `dir`, such as "enclave".
  def gemspec(dir)
    paths = Dir.glob(File.join(REPO_ROOT, dir, "*.gemspec"))
    raise "expected one gemspec in #{dir}/, found #{paths.inspect}" unless paths.size == 1

    load(paths.first)
  end

  # The gemspec file of the repo gem named `name`, or nil if no repo gem has
  # that name.
  def gemspec_path_of(name)
    Dir.glob(File.join(REPO_ROOT, "*", "*.gemspec")).find { |p| load(p).name == name }
  end

  # Gem::Specification.load returns nil for a gemspec that fails to load, so
  # say which one instead of failing later on nil.
  def load(path)
    Gem::Specification.load(path) or raise "couldn't load the gemspec #{path}"
  end
end
