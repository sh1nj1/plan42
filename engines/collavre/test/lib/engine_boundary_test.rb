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
# What is left is a clean binary: a core source file reaching a satellite, by
# naming its constant or by requiring one of its files. Every such reference in
# shipped code is either zero or recorded in KNOWN_VIOLATIONS, so this test
# stays green on the codebase as it is and exists to make the next violation
# loud instead of invisible.
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

  REQUIRE_METHODS = %w[require require_relative require_dependency].freeze

  RUBY_FILE = /\.(rb|rake|erb)\z/

  # One core migration already reaches satellites, deliberately and behind
  # `defined?` guards, and a migration that has run in production cannot be
  # edited. Recording it is the honest option: narrowing the scan to hide it
  # would also hide every migration written from here on.
  #
  # Entries are asserted below to still be real violations, so a stale one
  # fails the suite instead of quietly granting permanent amnesty — the same
  # rule the complexity baseline follows.
  KNOWN_VIOLATIONS = {
    "engines/collavre/db/migrate/20260120045354_encrypt_oauth_tokens.rb" => %w[CollavreGithub CollavreNotion]
  }.freeze

  test "satellite engines exist to be checked" do
    assert_operator SATELLITES.size, :>=, 2,
      "boundary test found no satellite engines — the discovery glob is broken, not the codebase"
  end

  test "core engine source never loads or references a satellite engine" do
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
    satellite_deps = core_gemspec.dependencies.map(&:name) & SATELLITES

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

  test "detector flags a require of a satellite engine" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/some_service" ], requires_in(%(require "#{satellite}/some_service"))
    assert_equal [ satellite ], requires_in(%(require_relative("#{satellite}")))
  end

  test "detector ignores requires of the core engine and third-party gems" do
    assert_empty requires_in(%(require "#{CORE}/engine"))
    assert_empty requires_in(%(require "net/http"))
  end

  test "detector ignores a satellite name inside an unrelated string" do
    satellite = SATELLITES.first

    assert_empty requires_in(%(warn "#{satellite} is not loaded"))
    assert_empty requires_in("# require \"#{satellite}\" would be a violation")
  end

  # Traversal is the obvious way around a check that only reads the first path
  # segment, and it is the form a real sibling dependency would actually take:
  # engines are siblings on disk, so `require_relative` between them is spelled
  # with "..".
  test "detector flags a satellite reached by relative traversal" do
    satellite = SATELLITES.first
    traversal = "../../#{satellite}/lib/#{satellite}/engine"

    assert_equal [ traversal ], requires_in(%(require_relative "#{traversal}"))
    assert_equal [ "./#{satellite}/x" ], requires_in(%(require "./#{satellite}/x"))
    assert_equal satellite, satellite_for(traversal)
  end

  test "detector does not mistake traversal past an unrelated directory for a satellite" do
    assert_empty requires_in(%(require_relative "../../support/net/http"))
  end

  # A hand-written glob has now missed shipped Ruby twice — `.rake`, then `db/`
  # and the `Rakefile`. These pin the file classes that were invisible, so the
  # coverage regression fails here rather than going quiet again.
  test "core source scan covers every kind of Ruby the engine ships" do
    %w[app/ lib/ db/migrate/ .rake Rakefile].each do |marker|
      assert core_sources.any? { |path| relative(path).include?(marker) },
        "core engine scan found nothing matching #{marker.inspect} — packaged Ruby is invisible to the boundary check"
    end
  end

  # A recorded exception is the strongest thing this test can hand out. If the
  # migration is ever squashed away, or the reference removed, the entry has to
  # go with it — otherwise the list rots into a permanent blind spot.
  test "recorded exceptions are still real violations" do
    KNOWN_VIOLATIONS.each do |path, constants|
      full = Rails.root.join(path)
      assert File.file?(full), "#{path} is recorded in KNOWN_VIOLATIONS but no longer exists — delete the entry"

      found = constants_in(File.read(full))
      assert_equal constants.sort, found.sort,
        "#{path} no longer references exactly #{constants.join(', ')} — update or delete its KNOWN_VIOLATIONS entry"
    end
  end

  private

  # Derived from the gemspec's own file list rather than a hand-maintained
  # glob. Two review rounds found Ruby the glob did not cover — `.rake` tasks,
  # then `db/` (154 files) and the `Rakefile` — because the glob and the
  # packaging manifest were maintained separately and drifted. Reading the
  # manifest means whatever the engine ships is scanned by construction,
  # including directories added later.
  def core_sources
    root = ENGINES_ROOT.join(CORE)
    packaged = core_gemspec.files.select { |path| path.match?(RUBY_FILE) || File.basename(path) == "Rakefile" }

    # The gemspec does not package itself, and it is Ruby that can require.
    (packaged.map { |path| root.join(path).to_s } << root.join("#{CORE}.gemspec").to_s).select { |path| File.file?(path) }
  end

  def core_gemspec
    @core_gemspec ||= Gem::Specification.load(ENGINES_ROOT.join(CORE, "#{CORE}.gemspec").to_s)
  end

  def violations_in(path)
    source = File.read(path)
    # ERB is not Ruby, so lex only the fragments between the tags.
    ruby = path.end_with?(".erb") ? source.scan(/<%=?-?(.*?)-?%>/m).flatten.join("\n") : source
    known = KNOWN_VIOLATIONS.fetch(relative(path), [])

    (constants_in(ruby) - known).map { |constant|
      "  #{relative(path)} references #{constant} (engines/#{SATELLITE_CONSTANTS[constant]})"
    } + requires_in(ruby).map { |feature|
      "  #{relative(path)} requires \"#{feature}\" (engines/#{satellite_for(feature)})"
    }
  end

  # Lexing rather than grepping: `# see CollavreSlack for the pattern` and
  # "CollavreNotion" inside a doc string are not dependencies, and the two
  # existing mentions in the core engine are both comments. A regex would fail
  # this test on day one for no reason.
  def constants_in(source)
    tokens(source)
      .select { |token| token.type == :CONSTANT }
      .map(&:value)
      .uniq
      .select { |value| SATELLITE_CONSTANTS.key?(value) }
  end

  # A constant is not the only way to reach a satellite. Every engine is on the
  # load path via the host Gemfile, so `require "collavre_slack/some_service"`
  # in a core file is a working, undeclared core-to-satellite dependency that
  # names no constant and adds no gemspec entry — invisible to both other
  # checks.
  #
  # The require target is matched on the token that follows the call, not by
  # grepping for the engine name, so prose that happens to mention an engine
  # ("collavre_slack is not loaded" in a warn) is not a violation.
  def requires_in(source)
    all = tokens(source)
    all.each_with_index.filter_map { |token, index|
      next unless token.type == :IDENTIFIER && REQUIRE_METHODS.include?(token.value)

      # `require "x"` and `require("x")` — the literal is within three tokens.
      feature = all[index + 1, 3].to_a.find { |candidate| candidate.type == :STRING_CONTENT }&.value
      feature if satellite_for(feature)
    }.uniq
  end

  # The engine is identified from every path segment after normalization, not
  # from the first one. A sibling engine is reachable by traversal —
  # `require_relative "../../collavre_slack/lib/collavre_slack/engine"` starts
  # with ".." and `require "./collavre_notion/x"` starts with "." — so matching
  # only the leading segment lets both through while the dependency is real.
  def satellite_for(feature)
    return nil if feature.nil?

    Pathname.new(feature).cleanpath.each_filename.find { |segment| SATELLITES.include?(segment) }
  end

  def tokens(source)
    Prism.lex(source).value.map(&:first)
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end
end
