# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# `bundle exec rake` is the one command that runs lint and every spec. These
# specs hold the Rakefile to that.
RSpec.describe "the Rakefile" do
  def rake(*, chdir:)
    Open3.capture2e(RbConfig.ruby, "-S", "rake", *, chdir: chdir)
  end

  def spec_suites
    out, status = Open3.capture2e(RbConfig.ruby, "-e", 'require "rake"; load "Rakefile"; puts SPEC_SUITES',
                                  chdir: REPO_ROOT)
    raise out unless status.success?

    out.split("\n")
  end

  it "lists every directory that has a spec/ folder in SPEC_SUITES" do
    dirs = Dir.glob("**/spec/", base: REPO_ROOT).reject { |d| d.start_with?("vendor/") }
    suites = dirs.map { |d| d == "spec/" ? "." : d.delete_suffix("/spec/") }

    expect(suites).to include(".", "enclave", "driver", "protocol")
    expect(spec_suites).to match_array(suites)
  end

  it "runs RuboCop and then the specs by default" do
    out, status = rake("-P", chdir: REPO_ROOT)

    expect(status).to be_success, out
    expect(out[/^rake default\n((?:    .*\n)*)/, 1]).to eq("    rubocop\n    spec\n")
  end

  # Runs the real Rakefile's spec task in a scratch copy of the repo layout,
  # where each suite holds one spec that passes or fails as told.
  describe "the spec task" do
    def run_suites(failing: nil)
      Dir.mktmpdir do |dir|
        FileUtils.cp(File.join(REPO_ROOT, "Rakefile"), dir)
        spec_suites.each do |suite|
          name = suite == "." ? "root" : suite
          FileUtils.mkdir_p(File.join(dir, suite, "spec"))
          File.write(File.join(dir, suite, "spec", "#{name}_spec.rb"), <<~RUBY)
            RSpec.describe("#{name}") { it("runs") { puts "ran:#{name}"; expect(#{suite != failing}).to eq(true) } }
          RUBY
        end
        rake("spec", chdir: dir)
      end
    end

    it "runs every suite when they all pass" do
      out, status = run_suites

      expect(status).to be_success, out
      expect(out.scan(/^ran:(\S+)$/).flatten).to contain_exactly("protocol", "enclave", "driver", "root")
    end

    it "fails when a gem's suite fails" do
      out, status = run_suites(failing: "enclave")

      expect(status).not_to be_success, out
    end

    it "fails when the cross-gem suite fails" do
      out, status = run_suites(failing: ".")

      expect(status).not_to be_success, out
    end
  end
end
