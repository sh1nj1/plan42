# frozen_string_literal: true

require "test_helper"
require "prism"

# Enforces the one engine rule that is genuinely one-directional
# (docs/conventions.md "Separation Rules" #2): every `collavre_*` engine may
# depend on `collavre`, never the reverse.
#
# Scope is deliberately narrow, and stays narrow on purpose.
#
# The broader rule — "all extension goes through IntegrationRegistry" — is NOT
# asserted here, because docs/conventions.md and docs/host_architecture.md both
# explicitly bless satellites injecting associations into core models from an
# initializer. A test that contradicted the documented architecture would be
# deleted, not obeyed.
#
# Nor is this an adversarial gate. It checks two static, literal things:
#
#   1. a core Ruby file naming a satellite constant, and
#   2. a core Ruby file loading a satellite path by string literal.
#
# It is deliberately possible to defeat by writing the reference dynamically —
# `"Collavre" + "Github"`, `const_get(computed)`, an interpolated require path.
# Chasing those is an unbounded surface (every reflection API, every way to
# build a string), and the payoff is zero: defeating this check takes
# deliberate obfuscation, and deliberate obfuscation is what code review is
# for. The value here is catching the accidental reference — someone reaching
# for `CollavreGithub::Account` in core because it was convenient — and that
# reference is always written plainly.
#
# Today the count is zero outside KNOWN_VIOLATIONS. This test exists to keep it
# that way: to make the next accidental reference loud instead of invisible.
class EngineBoundaryTest < ActiveSupport::TestCase
  ENGINES_ROOT = Rails.root.join("engines")
  CORE = "collavre"

  # Satellites are discovered rather than listed: a new engine has to be
  # covered from the day it lands, not from the day someone remembers to edit
  # this test.
  SATELLITES = Dir.children(ENGINES_ROOT)
    .select { |name| File.directory?(ENGINES_ROOT.join(name)) && name.start_with?("#{CORE}_") }
    .sort
    .freeze

  # Matched against the discovered set rather than a `collavre_` prefix, so
  # `collavre_githubish` — a vendored patch directory, not an engine — is not
  # reported as a dependency on a directory that does not exist.
  SATELLITE_CONSTANTS = SATELLITES.map(&:camelize).freeze

  # The gemspec is the one place the prefix is the right test: a satellite
  # published to RubyGems but absent from this checkout is still a dependency
  # the core gem cannot declare.
  SATELLITE_GEM_NAME = /\Acollavre_/
  RUBY_FILE = /\.(rb|rake)\z/

  # `require_relative` and `require_dependency` resolve a satellite file just
  # as well as `require`; `load` and `autoload` leave behind neither a constant
  # nor a gemspec entry.
  LOADER_METHODS = %w[require require_relative require_dependency load autoload].freeze

  # Two core migrations reach a satellite by constant, and a migration that has
  # run in production cannot be edited. Recording them is the honest option:
  # narrowing the scan to hide them would also hide every migration written
  # from here on.
  #
  # Recorded as a multiset of the exact classes reached, not as the engine
  # namespace. Waiving "CollavreGithub" for a file would waive every present
  # and future reference to anything under it; waiving
  # `CollavreGithub::Account` twice waives those two and nothing else.
  #
  # Entries are asserted below to still be real, so a stale one fails the suite
  # instead of rotting into a blind spot — the same rule the complexity
  # baseline follows.
  KNOWN_VIOLATIONS = {
    "engines/collavre/db/migrate/20260120045354_encrypt_oauth_tokens.rb" => [
      "CollavreGithub::Account",        # defined? guard
      "CollavreGithub::Account",        # encrypt_column argument
      "CollavreNotion::NotionAccount",  # defined? guard
      "CollavreNotion::NotionAccount"   # encrypt_column argument
    ]
  }.freeze

  test "satellite engines exist to be checked" do
    assert_operator SATELLITES.size, :>=, 2,
      "boundary test found no satellite engines — the discovery glob is broken, not the codebase"
  end

  test "core engine source never references or loads a satellite engine" do
    violations = core_sources.flat_map { |path| violations_in(path) }

    assert_empty violations, <<~MESSAGE
      The core engine must not depend on a satellite engine.

      #{violations.join("\n")}

      Invert the dependency: expose a hook from `collavre` (IntegrationRegistry,
      a config point, or an initializer in the satellite) and let the satellite
      register itself.
    MESSAGE
  end

  test "every recorded violation is still real" do
    KNOWN_VIOLATIONS.each do |path, expected|
      source = File.read(Rails.root.join(path))

      assert_equal expected.tally, constant_references_in(source).tally,
        "#{path} no longer matches its KNOWN_VIOLATIONS entry — update the entry rather than leaving it to rot"
    end
  end

  test "core engine gemspec declares no satellite dependency" do
    satellite_deps = core_gemspec.dependencies.map(&:name).grep(SATELLITE_GEM_NAME)

    assert_empty satellite_deps,
      "engines/#{CORE}/#{CORE}.gemspec depends on #{satellite_deps.join(', ')} — the core engine cannot require a satellite"
  end

  test "detector flags a satellite constant reference" do
    assert_equal [ "CollavreGithub::Account" ],
      constant_references_in("CollavreGithub::Account.find(id)")
  end

  test "detector reports the class reached, not just the engine namespace" do
    assert_equal [ "CollavreSlack::Channel::Message" ],
      constant_references_in("CollavreSlack::Channel::Message.new")
  end

  test "detector keeps every occurrence rather than collapsing duplicates" do
    assert_equal [ "CollavreGithub::Account", "CollavreGithub::Account" ],
      constant_references_in("CollavreGithub::Account.first || CollavreGithub::Account.new")
  end

  test "detector ignores satellite names in comments and strings" do
    source = <<~RUBY
      # see CollavreSlack::Channel for the pattern
      log("CollavreNotion::NotionAccount handles this")
    RUBY

    assert_empty constant_references_in(source)
  end

  test "detector ignores the core engine's own constants and lookalikes" do
    assert_empty constant_references_in("Collavre::Creative.new; CollavreGithubish::Thing.new")
  end

  test "detector ignores a satellite name nested under another namespace" do
    assert_empty constant_references_in("Wrapper::CollavreSlack.call")
  end

  test "detector flags a require of a satellite engine" do
    assert_equal [ "collavre_github/account" ],
      loader_paths_in('require "collavre_github/account"')
  end

  test "detector flags load and autoload of a satellite engine" do
    source = <<~RUBY
      load "collavre_slack/channel.rb"
      autoload :Channel, "collavre_notion/channel"
    RUBY

    assert_equal [ "collavre_slack/channel.rb", "collavre_notion/channel" ], loader_paths_in(source)
  end

  test "detector ignores requires of the core engine and third-party gems" do
    source = <<~RUBY
      require "collavre"
      require "collavre/creative"
      require "net/http"
    RUBY

    assert_empty loader_paths_in(source)
  end

  test "detector ignores a satellite name that is not a path segment" do
    assert_empty loader_paths_in('require "vendor/collavre_githubish/patch"')
  end

  test "detector ignores a satellite name inside an unrelated string" do
    assert_empty loader_paths_in('log("collavre_github/account is not loaded")')
  end

  private

  # Derived from the gemspec's own file list rather than a hand-maintained
  # glob: whatever the engine ships is scanned by construction, including
  # directories added later.
  def core_sources
    root = ENGINES_ROOT.join(CORE)
    packaged = core_gemspec.files.select { |path| path.match?(RUBY_FILE) || File.basename(path) == "Rakefile" }

    # The gemspec does not package itself, and it is Ruby that can require.
    (packaged.map { |path| root.join(path).to_s } << root.join("#{CORE}.gemspec").to_s)
      .select { |path| File.file?(path) }
  end

  def core_gemspec
    @core_gemspec ||= Gem::Specification.load(ENGINES_ROOT.join(CORE, "#{CORE}.gemspec").to_s)
  end

  def violations_in(path)
    source = File.read(path)
    known = KNOWN_VIOLATIONS.fetch(relative(path), []).dup

    unwaived(constant_references_in(source), known).map { |name|
      "  #{relative(path)} references #{name} (engines/#{name.split('::').first.underscore})"
    } + loader_paths_in(source).map { |feature|
      "  #{relative(path)} loads \"#{feature}\" (engines/#{satellite_for(feature)})"
    }
  end

  def unwaived(references, known)
    references.reject { |name| (index = known.index(name)) && known.delete_at(index) }
  end

  # Lexing rather than grepping: `# see CollavreSlack for the pattern` and
  # "CollavreNotion" inside a doc string are not dependencies, and the two
  # existing mentions in the core engine are both comments. A regex would fail
  # this test on day one for no reason.
  #
  # The `::`-joined tail is walked so the result is the class actually reached,
  # not just its engine namespace. Reporting `CollavreGithub` for
  # `CollavreGithub::Account` is fine for a message but useless for a waiver,
  # which has to name one reference rather than one engine.
  def constant_references_in(source)
    all = Prism.lex(source).value.map(&:first)

    all.each_with_index.filter_map do |token, index|
      next unless token.type == :CONSTANT && SATELLITE_CONSTANTS.include?(token.value)
      # `Wrapper::CollavreSlack` is Wrapper's own nested constant, and
      # `:CollavreSlack` is data until something resolves it.
      next if %i[COLON_COLON SYMBOL_BEGIN].include?(all[index - 1]&.type) && index.positive?

      qualified_from(all, index)
    end
  end

  def qualified_from(all, index)
    name = +all[index].value
    cursor = index + 1
    while all[cursor]&.type == :COLON_COLON && all[cursor + 1]&.type == :CONSTANT
      name << "::" << all[cursor + 1].value
      cursor += 2
    end
    name
  end

  # Only literal string arguments to a bare (or `self.`) loader call. An
  # interpolated or computed path is out of scope by design — see the class
  # comment.
  def loader_paths_in(source)
    loader_calls(Prism.parse(source).value).filter_map do |call|
      call.arguments&.arguments.to_a.grep(Prism::StringNode).map(&:unescaped).find { |path| satellite_for(path) }
    end
  end

  def loader_calls(node, found = [])
    return found unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::CallNode) && LOADER_METHODS.include?(node.name.to_s) && bare_receiver?(node.receiver)
      found << node
    end
    node.compact_child_nodes.each { |child| loader_calls(child, found) }
    found
  end

  def bare_receiver?(receiver)
    receiver.nil? || receiver.is_a?(Prism::SelfNode)
  end

  def satellite_for(feature)
    Pathname.new(feature.delete_suffix(".rb")).cleanpath.each_filename.find { |segment| SATELLITES.include?(segment) }
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end
end
