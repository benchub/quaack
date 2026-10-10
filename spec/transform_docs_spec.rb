# frozen_string_literal: true

require_relative "spec_helper"
require "quaack/enclave/rewrite_rules"

# Task 20261004-14: each transform rule has its own page,
# docs/transforms/<rule name>.md, and DESIGN.md's rewrite-rules table
# links to it. The report links a rule's name to that page, so a rule
# can't land without one.
RSpec.describe "docs/transforms" do
  let(:names) { Quaack::Enclave::RewriteRules::RULES.map(&:name) }
  let(:pages) { Dir[File.join(REPO_ROOT, "docs/transforms/*.md")].map { File.basename(it, ".md") } }

  it "has a page for every rule in RULES" do
    expect(names - pages).to eq([])
  end

  it "has no page that doesn't name a rule in RULES" do
    expect(pages - names).to eq([])
  end

  it "gives each page a heading of its rule's name, an example before and after, and what it needs" do
    names.each do |name|
      page = File.read(File.join(REPO_ROOT, "docs/transforms/#{name}.md"))
      expect(page.lines.first).to eq("# #{name}.\n")
      expect(page).to include("## Example.", "Before:", "After:", "## What it rests on.")
      expect(page.scan("```sql").size).to be >= 2, "#{name}.md has no before and after SQL"
    end
  end

  it "links every rule's page from DESIGN.md's rewrite-rules table, one line each" do
    design = File.read(File.join(REPO_ROOT, "DESIGN.md"))
    rows = design.lines.grep(%r{\A\| \[`\w+`\]\(docs/transforms/\w+\.md\) \|})
    expect(rows.map { it[/\[`(\w+)`\]/, 1] }).to eq(names)
    rows.each { |row| expect(row).to include("(docs/transforms/#{row[/\[`(\w+)`\]/, 1]}.md)") }
  end

  it "words each page as one of QUAACK's transform rules and links DESIGN.md's rewrite-rules heading" do
    names.each do |name|
      page = File.read(File.join(REPO_ROOT, "docs/transforms/#{name}.md"))
      expect(page).to include("It's one of QUAACK's transform rules " \
                              "(see [DESIGN.md's rewrite-rules](../../DESIGN.md#rewrite-rules-mechanical-rules)).")
      expect(page).not_to match(/mechanical (?:rewrite )?rules/i), "#{name}.md still says mechanical rules"
    end
  end

  # GitHub's anchor for a heading: lowercase, punctuation dropped, spaces to hyphens.
  it "has a DESIGN.md heading that the pages' anchor resolves to" do
    design = File.read(File.join(REPO_ROOT, "DESIGN.md"))
    anchors = design.lines.grep(/\A#+ /).map { it.sub(/\A#+ /, "").strip.downcase.gsub(/[^\w\s-]/, "").tr(" ", "-") }
    anchor = names.map { File.read(File.join(REPO_ROOT, "docs/transforms/#{it}.md"))[/DESIGN\.md#([\w-]+)/, 1] }.uniq

    expect(anchor).to eq(["rewrite-rules-mechanical-rules"])
    expect(anchors).to include("rewrite-rules-mechanical-rules")
  end

  it "says transform rules in the README's account of a rewrite that wasn't kept, and not mechanical rewrite rules" do
    readme = File.read(File.join(REPO_ROOT, "README.md"))
    expect(readme).to include("ten from the transform rules")
    expect(readme).not_to match(/mechanical rewrite rules/i)
  end
end
