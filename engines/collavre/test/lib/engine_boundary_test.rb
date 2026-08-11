# frozen_string_literal: true

require "test_helper"
require "prism"

# Enforces the one engine rule that is genuinely one-directional
# (docs/conventions.md "Separation Rules" #2): every `collavre_*` engine may
# depend on `collavre`, never the reverse.
#
# Scope is deliberately narrow. The broader rule — "all extension goes through
# IntegrationRegistry" — is NOT asserted here, because docs/conventions.md and
# docs/host_architecture.md both explicitly bless satellites injecting
# associations into core models from an initializer. A test that contradicted
# the documented architecture would be deleted, not obeyed.
#
# What is left is a clean binary: a core source file naming a satellite
# constant. Today that count is zero, so this test costs nothing to keep green
# and exists purely to make the first violation loud instead of invisible.
class EngineBoundaryTest < ActiveSupport::TestCase
  ENGINES_ROOT = Rails.root.join("engines")
  CORE = "collavre"

  # Satellites are discovered rather than listed: a new engine has to be covered
  # from the day it lands, not from the day someone remembers to edit this test.
  SATELLITES = Dir.children(ENGINES_ROOT)
    .select { |name| File.directory?(ENGINES_ROOT.join(name)) && name.start_with?("#{CORE}_") }
    .sort
    .freeze

  SATELLITE_CONSTANTS = SATELLITES.to_h { |name| [ name.camelize, name ] }.freeze

  test "satellite engines exist to be checked" do
    assert_operator SATELLITES.size, :>=, 2,
      "boundary test found no satellite engines — the discovery glob is broken, not the codebase"
  end

  test "core engine source never references a satellite engine constant" do
    violations = core_sources.flat_map { |path| violations_in(path) }

    assert_empty violations, <<~MESSAGE
      The core engine must not depend on a satellite engine.

      #{violations.join("\n")}

      Invert the dependency: expose a hook from `collavre` (IntegrationRegistry,
      a config point, or an initializer in the satellite) and let the satellite
      register itself.
    MESSAGE
  end

  test "core engine gemspec declares no satellite dependency" do
    gemspec = Gem::Specification.load(ENGINES_ROOT.join(CORE, "#{CORE}.gemspec").to_s)
    satellite_deps = gemspec.dependencies.map(&:name) & SATELLITES

    assert_empty satellite_deps,
      "engines/#{CORE}/#{CORE}.gemspec depends on #{satellite_deps.join(', ')} — the core engine cannot require a satellite"
  end

  # The three tests above pass today because the codebase is clean, which means
  # they would also pass if the detector were broken. These pin the detector
  # itself.
  test "detector flags a real satellite constant reference" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_equal [ satellite ], constants_in("#{satellite}::Account.find(1)")
    assert_equal [ satellite ], constants_in("if defined?(#{satellite})\n  1\nend")
  end

  test "detector ignores satellite names in comments and strings" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_empty constants_in("# see #{satellite} for the pattern")
    assert_empty constants_in(%(warn "#{satellite} is not loaded"))
  end

  test "detector ignores the core engine's own constants" do
    assert_empty constants_in("Collavre::Creative.first")
  end

  private

  def core_sources
    Dir.glob(ENGINES_ROOT.join(CORE, "{app,lib,config}", "**", "*.{rb,erb}"))
  end

  def violations_in(path)
    source = File.read(path)
    referenced = if path.end_with?(".erb")
      # ERB is not Ruby, so lex only the fragments between the tags.
      constants_in(source.scan(/<%=?-?(.*?)-?%>/m).flatten.join("\n"))
    else
      constants_in(source)
    end

    referenced.map do |constant|
      "  #{relative(path)} references #{constant} (engines/#{SATELLITE_CONSTANTS[constant]})"
    end
  end

  # Lexing rather than grepping: `# see CollavreSlack for the pattern` and
  # "CollavreNotion" inside a doc string are not dependencies, and the two
  # existing mentions in the core engine are both comments. A regex would fail
  # this test on day one for no reason.
  def constants_in(source)
    Prism.lex(source).value
      .select { |token, _state| token.type == :CONSTANT }
      .map { |token, _state| token.value }
      .uniq
      .select { |value| SATELLITE_CONSTANTS.key?(value) }
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end
end
