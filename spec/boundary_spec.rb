# frozen_string_literal: true

# The driver and the enclave script run on different machines, on opposite
# sides of the trust boundary. See DESIGN.md, "Where QUAACK runs." These are
# the static checks: they fail if either gem declares or requires the other,
# or if the enclave can reach an LLM SDK. runtime_boundary_spec.rb holds the
# runtime check.
RSpec.describe "the driver/enclave boundary" do
  def gem_dir(name) = File.join(REPO_ROOT, name)

  def gemspec(dir) = RepoGems.gemspec(dir)

  def violation_report(violations) = violations.join("\n")

  describe "the enclave gem" do
    let(:closure) { Boundary.dependency_closure(gemspec("enclave")) }

    # Any new dependency fails here until someone reviews it and adds it to
    # Boundary::ENCLAVE_ALLOWED_GEMS. The runtime check uses the same list.
    it "depends on exactly the reviewed gems" do
      expect(closure.names).to contain_exactly(*Boundary::ENCLAVE_ALLOWED_GEMS)
      expect(closure.unresolved).to eq([])
    end

    it "never requires the driver gem, an LLM SDK, or a file outside itself" do
      violations = Boundary.require_violations(gem_dir("enclave"), forbidden: Boundary::ENCLAVE_FORBIDDEN_REQUIRES)

      expect(violations).to be_empty, violation_report(violations)
    end

    it "has its library and executable actually scanned" do
      files = Boundary.source_files(gem_dir("enclave")).map { |f| f.delete_prefix("#{gem_dir("enclave")}/") }

      expect(files).to include("lib/quaack/enclave.rb", "lib/quaack/enclave/cli.rb", "exe/quaacks")
    end
  end

  describe "the protocol gem" do
    # Both sides load it, so it must obey both sides' rules.
    it "depends on nothing at all" do
      closure = Boundary.dependency_closure(gemspec("protocol"))

      expect(closure.names).to eq([])
      expect(closure.unresolved).to eq([])
    end

    it "never requires the driver gem, the enclave gem, an LLM SDK, or a file outside itself" do
      violations = Boundary.require_violations(gem_dir("protocol"), forbidden: Boundary::PROTOCOL_FORBIDDEN_REQUIRES)

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

    # Keyed on the enclave gemspec's own name, so a rename can't leave this
    # check looking for a gem that no longer exists.
    it "doesn't depend, directly or transitively, on the enclave gem" do
      expect(closure.names).not_to include(gemspec("enclave").name)
      expect(closure.unresolved).to eq([])
    end

    it "has its dependency tree actually walked" do
      expect(closure.names).to include("quaack-protocol")
    end

    # Loading enclave code on a laptop leaks no production data, so the
    # driver gets only the forbidden-name rule.
    it "never requires the enclave gem" do
      violations = Boundary.require_violations(gem_dir("driver"), forbidden: Boundary::DRIVER_FORBIDDEN_REQUIRES,
                                                                  names_only: true)

      expect(violations).to be_empty, violation_report(violations)
    end

    it "has its library and executable actually scanned" do
      files = Boundary.source_files(gem_dir("driver")).map { |f| f.delete_prefix("#{gem_dir("driver")}/") }

      expect(files).to include("lib/quaack/driver.rb", "lib/quaack/driver/cli.rb", "exe/quaack")
    end
  end
end
