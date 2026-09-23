# frozen_string_literal: true

# The driver and the enclave script run on different machines, on opposite
# sides of the trust boundary. See README.md, "Where QUAACK runs." These specs
# fail if either gem reaches into the other, or if the enclave can load an LLM
# SDK.
RSpec.describe "the driver/enclave boundary" do
  def gem_dir(name) = File.join(REPO_ROOT, name)

  def gemspec(name)
    Gem::Specification.load(File.join(gem_dir(name), "quaack-#{name}.gemspec"))
  end

  def violation_report(violations) = violations.join("\n")

  enclave_forbidden_gems = ["quaack-driver", *Boundary::LLM_SDK_GEMS]
  enclave_forbidden_requires = ["quaack/driver", *Boundary::LLM_SDK_REQUIRES]

  describe "the enclave gem" do
    let(:closure) { Boundary.dependency_closure(gemspec("enclave")) }

    it "doesn't depend, directly or transitively, on the driver gem or an LLM SDK" do
      expect(closure.names & enclave_forbidden_gems).to eq([])
      expect(closure.unresolved).to eq([])
    end

    it "has its dependency tree actually walked" do
      # pg_query pulls in google-protobuf, so seeing it proves the walk went
      # past direct dependencies.
      expect(closure.names).to include("pg_query", "quaack-protocol", "google-protobuf")
    end

    it "never requires the driver gem, an LLM SDK, or a file outside itself" do
      violations = Boundary.require_violations(gem_dir("enclave"), forbidden: enclave_forbidden_requires)

      expect(violations).to be_empty, violation_report(violations)
    end

    it "has its library and executable actually scanned" do
      files = Boundary.source_files(gem_dir("enclave")).map { |f| f.delete_prefix("#{gem_dir("enclave")}/") }

      expect(files).to include("lib/quaack/enclave.rb", "lib/quaack/enclave/cli.rb", "exe/quaack-enclave")
    end
  end

  describe "the protocol gem" do
    # Both sides load it, so it must obey both sides' rules.
    it "doesn't depend on the driver gem, the enclave gem, or an LLM SDK" do
      closure = Boundary.dependency_closure(gemspec("protocol"))

      expect(closure.names & ["quaack-enclave", *enclave_forbidden_gems]).to eq([])
      expect(closure.unresolved).to eq([])
    end

    it "never requires the driver gem, the enclave gem, an LLM SDK, or a file outside itself" do
      violations = Boundary.require_violations(
        gem_dir("protocol"), forbidden: ["quaack/enclave", *enclave_forbidden_requires]
      )

      expect(violations).to be_empty, violation_report(violations)
    end

    it "has its library actually scanned" do
      expect(Boundary.source_files(gem_dir("protocol"))).to include(
        File.join(gem_dir("protocol"), "lib", "quaack", "protocol.rb")
      )
    end
  end

  describe "the driver gem" do
    let(:closure) { Boundary.dependency_closure(gemspec("driver")) }

    it "doesn't depend, directly or transitively, on the enclave gem" do
      expect(closure.names).not_to include("quaack-enclave")
      expect(closure.unresolved).to eq([])
    end

    it "has its dependency tree actually walked" do
      expect(closure.names).to include("quaack-protocol")
    end

    it "never requires the enclave gem or a file outside itself" do
      violations = Boundary.require_violations(gem_dir("driver"), forbidden: ["quaack/enclave"])

      expect(violations).to be_empty, violation_report(violations)
    end

    it "has its library and executable actually scanned" do
      files = Boundary.source_files(gem_dir("driver")).map { |f| f.delete_prefix("#{gem_dir("driver")}/") }

      expect(files).to include("lib/quaack/driver.rb", "lib/quaack/driver/cli.rb", "exe/quaack")
    end
  end
end
