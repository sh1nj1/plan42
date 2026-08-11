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

  # Every entry point that resolves a path through $LOAD_PATH. `load` and
  # `autoload` are not `require`, but they reach a satellite file just as well
  # and leave behind neither a constant nor a gemspec entry. See
  # #loader_receiver? for why `autoload` is matched on any receiver and the rest
  # only on Kernel.
  LOADER_METHODS = %w[require require_relative require_dependency load autoload].freeze

  # A satellite class named inside a string is a dependency too — Rails
  # resolves `class_name:`, `constantize` and an STI `type` value to the real
  # constant at run time, and the core engine breaks if the satellite renames
  # it. Matched anywhere inside the literal rather than only as the whole
  # string, because the live case in this repo is an STI type inside a SQL
  # heredoc. Comments lex as COMMENT, not STRING_CONTENT, so prose about an
  # engine is still not a violation.
  #
  # The nested segments are captured too, so a reference is recorded as the
  # class it actually reaches rather than as its engine namespace — see
  # KNOWN_VIOLATIONS for why that distinction is the whole point.
  SATELLITE_IN_STRING = /\b(?:#{SATELLITE_CONSTANTS.keys.join('|')})(?:::[A-Z]\w*)*\b/

  RUBY_FILE = /\.(rb|rake|erb)\z/

  # Two core migrations already reach satellites — one by constant behind
  # `defined?` guards, one by STI type string — and a migration that has run in
  # production cannot be edited. Recording them is the honest option: narrowing
  # the scan to hide them would also hide every migration written from here on.
  #
  # Recorded as a multiset of the exact classes reached, not as the engine
  # namespace. Waiving "CollavreGithub" for a file waives every present and
  # future reference to anything under it, so the exception quietly widens into
  # permanent amnesty for that whole engine; waiving `CollavreGithub::Account`
  # three times waives those three and nothing else. A fourth occurrence, or a
  # different class under the same engine, is a new violation.
  #
  # Entries are asserted below to still be real violations, so a stale one
  # fails the suite instead of rotting into a blind spot — the same rule the
  # complexity baseline follows.
  KNOWN_VIOLATIONS = {
    "engines/collavre/db/migrate/20260120045354_encrypt_oauth_tokens.rb" => [
      "CollavreGithub::Account",         # defined? guard
      "CollavreGithub::Account",         # encrypt_column argument
      "CollavreGithub::Account",         # say_with_time message
      "CollavreNotion::NotionAccount",   # defined? guard
      "CollavreNotion::NotionAccount",   # encrypt_column argument
      "CollavreNotion::NotionAccount"    # say_with_time message
    ],
    "engines/collavre/db/migrate/20260527000100_backfill_dismissed_at_for_legacy_detached_channels.rb" => [
      "CollavreGithub::GithubPrChannel" # STI type in the SQL
    ]
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

    assert_equal [ "#{satellite}::Account" ], names(constant_references_in("#{satellite}::Account.find(1)"))
    assert_equal [ satellite ], names(constant_references_in("if defined?(#{satellite})\n  1\nend"))
  end

  # A waiver names one class, so the detector has to report one class. Stopping
  # at the engine namespace would make every entry in KNOWN_VIOLATIONS an
  # engine-wide exception no matter how it was written.
  test "detector reports the class reached, not just the engine namespace" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_equal [ "#{satellite}::Accounts::Token" ], names(constant_references_in("#{satellite}::Accounts::Token.new"))
    assert_empty names(constant_references_in("Wrapper::#{satellite}.call"))
  end

  # Top-level constants are constants of Object, so `Object::` reaches the
  # engine while every other qualifier names somebody else's nested constant.
  # Recorded without the qualifier, because it resolves to the same class and a
  # waiver should not depend on how the reference was spelled.
  test "detector flags a satellite reached through Object" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_equal [ "#{satellite}::Account" ], names(constant_references_in("Object::#{satellite}::Account.find(1)"))
    assert_equal [ "#{satellite}::Account" ], names(constant_references_in("::Object::#{satellite}::Account.find(1)"))
    assert_equal [ "#{satellite}::Account" ], names(constant_references_in("::#{satellite}::Account.find(1)"))
    assert_equal [ satellite ], names(constant_references_in("Object::#{satellite}.thing"))
  end

  # The counterpart: only the real Object qualifies. A nested `Wrapper::Object`
  # is an ordinary namespace, and `Wrapper::Object::CollavreSlack` is Wrapper's
  # constant rather than the engine.
  test "detector ignores a satellite nested under a namespace named Object" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_empty names(constant_references_in("Wrapper::Object::#{satellite}.call"))
    assert_empty names(constant_references_in("Wrapper::Object::#{satellite}::Account.find(1)"))
  end

  # Duplicates are what make a waiver cancel one occurrence instead of a class
  # of them, so the detector must not collapse them.
  test "detector keeps every occurrence rather than collapsing duplicates" do
    satellite = SATELLITE_CONSTANTS.keys.first
    source = "#{satellite}::Account.first\n#{satellite}::Account.last\n"

    assert_equal [ "#{satellite}::Account" ] * 2, names(constant_references_in(source))
    assert_equal [ "#{satellite}::Account" ] * 2, names(string_references_in(%("#{satellite}::Account" + "#{satellite}::Account")))
  end

  test "detector ignores satellite names in comments and strings" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_empty names(constant_references_in("# see #{satellite} for the pattern"))
    assert_empty names(constant_references_in(%(warn "#{satellite} is not loaded")))
  end

  test "detector ignores the core engine's own constants" do
    assert_empty names(constant_references_in("Collavre::Creative.first"))
  end

  # Rails resolves a class from a string in several places, and none of them
  # leave a CONSTANT token behind. All three forms below are live Rails idiom.
  test "detector flags a satellite class named in a string" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_equal [ "#{satellite}::Account" ], names(string_references_in(%(belongs_to :account, class_name: "#{satellite}::Account")))
    assert_equal [ "#{satellite}::Account" ], names(string_references_in(%("#{satellite}::Account".constantize)))
    assert_equal [ satellite ], names(string_references_in(%(Object.const_get("#{satellite}"))))
  end

  # The live case in this repo: an STI type inside a SQL heredoc, which lexes as
  # one STRING_CONTENT holding the whole query. Matching only whole-string
  # constants would miss it.
  test "detector flags a satellite class named inside a heredoc" do
    satellite = SATELLITE_CONSTANTS.keys.first
    source = "execute <<~SQL\n  UPDATE channels SET x = 1 WHERE type = '#{satellite}::PrChannel'\nSQL\n"

    assert_equal [ "#{satellite}::PrChannel" ], names(string_references_in(source))
  end

  test "string detector ignores comments and the core engine's own constants" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_empty names(string_references_in("# see #{satellite}::Account for the pattern"))
    assert_empty names(string_references_in(%("Collavre::Creative")))
    assert_empty names(string_references_in(%("#{satellite}Extra::Account")))
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

  # `require` is not Ruby's only load-path entry point. `load` and `autoload`
  # reach the same file with the same effect and were invisible here, so a core
  # file could take a satellite dependency that named no constant, added no
  # gemspec entry, and used no require.
  test "detector flags a satellite reached by load or autoload" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/some_service.rb" ], requires_in(%(load "#{satellite}/some_service.rb"))
    assert_equal [ "#{satellite}/some_service.rb" ], requires_in(%(Kernel.load("#{satellite}/some_service.rb")))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(autoload :Foo, "#{satellite}/foo"))
  end

  # `load` is an ordinary method name. Flagging it on any receiver would fail
  # this test on a YAML read that happens to sit under a satellite path, and a
  # gate that cries wolf gets deleted.
  test "detector ignores load on a receiver other than Kernel" do
    satellite = SATELLITES.first

    assert_empty requires_in(%(YAML.load "config/#{satellite}/settings.yml"))
    assert_empty requires_in(%(registry.load_all("#{satellite}")))
  end

  # Holding `require` and `load` to Kernel is only sound if every spelling of
  # Kernel counts. `::Kernel` parses as a ConstantPathNode rather than a
  # ConstantReadNode, so a working loader call was skipped over a difference in
  # how the receiver was written.
  test "detector flags a Kernel loader however Kernel is qualified" do
    satellite = SATELLITES.first
    feature = "#{satellite}/some_service"

    assert_equal [ feature ], requires_in(%(::Kernel.require "#{feature}"))
    assert_equal [ "#{feature}.rb" ], requires_in(%(::Kernel.load "#{feature}.rb"))
    assert_equal [ feature ], requires_in(%(Object::Kernel.require "#{feature}"))
    assert_equal [ feature ], requires_in(%(::Object::Kernel.require "#{feature}"))
  end

  # The counterpart. A nested `Wrapper::Kernel` is somebody else's constant and
  # raises NameError in Ruby, so the walk has to reach the root rather than
  # accept any path whose last segment reads "Kernel".
  test "detector ignores a loader on a Kernel nested under another namespace" do
    satellite = SATELLITES.first

    assert_empty requires_in(%(Wrapper::Kernel.load "#{satellite}/x.rb"))
    assert_empty requires_in(%(Wrapper::Object::Kernel.load "#{satellite}/x.rb"))
  end

  # `autoload` is Module#autoload, so a module receiver is its ordinary form —
  # the opposite of `load`, where the bare call is the ordinary one. Holding
  # both to the Kernel rule would have missed the spelling people actually
  # write.
  test "detector flags autoload on a module receiver" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/foo" ], requires_in(%(Collavre.autoload :Foo, "#{satellite}/foo"))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(Collavre::Integrations.autoload(:Foo, "#{satellite}/foo")))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(mod&.autoload :Foo, "#{satellite}/foo"))
  end

  # The path has to belong to the loader itself. A string in a *neighbouring*
  # call on the same line, or in a nested call the loader only takes the result
  # of, is somebody else's.
  test "detector does not read strings belonging to another call" do
    satellite = SATELLITES.first

    assert_empty requires_in(%(load(path) || warn("#{satellite} is missing")))
    assert_empty requires_in(%(require_relative File.join(__dir__, "#{satellite}")))
  end

  # Formatting was the recurring miss: parentheses moved the literal, and a call
  # split across lines put an IGNORED_NEWLINE where the old token walk stopped.
  # Reading the parsed arguments makes layout irrelevant, so these are all one
  # dependency spelled four ways.
  test "detector flags a loader however the call is laid out" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/foo" ], requires_in(%(require(\n  "#{satellite}/foo"\n)))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(require_dependency(\n  "#{satellite}/foo",\n)))
    assert_equal [ "#{satellite}/foo" ],
      requires_in(%(Collavre.autoload(\n  :Foo,\n  "#{satellite}/foo"\n)))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(require \\\n  "#{satellite}/foo"))
  end

  # A computed path still names the engine literally, so the static part of an
  # interpolated string counts. The negative matters as much: an exact segment
  # match means a longer name that merely starts with an engine's is not a hit.
  test "detector flags an interpolated path and ignores a longer look-alike" do
    satellite = SATELLITES.first

    assert_equal [ "/#{satellite}/foo" ], requires_in(%(require "\#{root}/#{satellite}/foo"))
    assert_empty requires_in(%(require "\#{root}/#{satellite}_stub/foo"))
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

  # The failure mode a file-level waiver has: it was written for one reference
  # and silently covers the next one too. Both halves matter — a waived
  # occurrence must stay waived, or the list is useless, and an unwaived one
  # must surface, or the list is amnesty.
  test "a waiver cancels one occurrence rather than every reference to the engine" do
    satellite = SATELLITE_CONSTANTS.keys.first
    source = "#{satellite}::Account.first\n#{satellite}::Account.last\n#{satellite}::Repository.all\n"

    assert_equal [ "#{satellite}::Account", "#{satellite}::Account", "#{satellite}::Repository" ],
      references_in(source).map(&:first)

    # Exactly what is recorded for the live migrations: the same class, listed
    # once per occurrence.
    assert_empty unwaived(references_in(source), [ "#{satellite}::Account" ] * 2 + [ "#{satellite}::Repository" ])

    # A third `::Account` is a new dependency even though `::Account` is waived.
    assert_equal [ [ "#{satellite}::Account", :constant ] ],
      unwaived(references_in(source), [ "#{satellite}::Account" ] + [ "#{satellite}::Repository" ])

    # And a different class under a waived engine is never covered by it.
    assert_equal [ [ "#{satellite}::Repository", :constant ] ],
      unwaived(references_in(source), [ "#{satellite}::Account" ] * 2)
  end

  # A recorded exception is the strongest thing this test can hand out. If the
  # migration is ever squashed away, or a reference removed, the entry has to go
  # with it — otherwise the list rots into a permanent blind spot.
  #
  # Compared as a multiset, so an added occurrence fails here as surely as a
  # removed one. An entry may only ever cover what is in the file right now.
  test "recorded exceptions are still real violations" do
    KNOWN_VIOLATIONS.each do |path, recorded|
      full = Rails.root.join(path)
      assert File.file?(full), "#{path} is recorded in KNOWN_VIOLATIONS but no longer exists — delete the entry"

      found = references_in(File.read(full)).map(&:first)
      assert_equal recorded.sort, found.sort, <<~MESSAGE
        #{path} no longer references exactly what KNOWN_VIOLATIONS records for it.

        A waiver covers the occurrences listed and no others, so update the entry
        to match the file — or delete it if the dependency is gone. Do not widen
        it to cover a new reference.
      MESSAGE
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
    # Requires are deliberately absent from the waiver: no core file has one
    # today, and a new one is never the frozen-migration case the list exists
    # for.
    known = KNOWN_VIOLATIONS.fetch(relative(path), [])

    unwaived(references_in(ruby), known).map { |name, kind|
      phrasing = kind == :string ? "names #{name} in a string" : "references #{name}"
      "  #{relative(path)} #{phrasing} (engines/#{engine_for(name)})"
    } + requires_in(ruby).map { |feature|
      "  #{relative(path)} requires \"#{feature}\" (engines/#{satellite_for(feature)})"
    }
  end

  # Multiset subtraction, not Array#-. `found - known` removes *every*
  # occurrence of a waived name, so a file waived for one reference to a class
  # is waived for ten. Each recorded entry cancels exactly one occurrence.
  def unwaived(references, known)
    remaining = known.dup
    references.reject { |name, _kind| (index = remaining.index(name)) && remaining.delete_at(index) }
  end

  # Every satellite reference as a [fully-qualified name, :constant | :string]
  # pair, duplicates preserved. Duplicates are what make a waiver cancel one
  # occurrence rather than a whole class of them.
  #
  # Sorted by line so that #unwaived, which cancels recorded entries in order,
  # blames the last occurrence of a name rather than the first. Occurrences of
  # one name are interchangeable to the waiver, so something has to be blamed;
  # blaming the newest one points the failure at the line somebody just wrote.
  def references_in(source)
    located = constant_references_in(source).map { |name, line| [ name, :constant, line ] } +
      string_references_in(source).map { |name, line| [ name, :string, line ] }

    # sort_by is not stable, and two references can share a line.
    located.each_with_index.sort_by { |(_name, _kind, line), index| [ line, index ] }
      .map { |(name, kind, _line), _index| [ name, kind ] }
  end

  def engine_for(name)
    SATELLITE_CONSTANTS[name.split("::").first]
  end

  # The detectors carry a line alongside each name so #references_in can order
  # them; the assertions above only care about the names.
  def names(located)
    located.map(&:first)
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
    all = tokens(source)
    all.each_with_index.filter_map { |token, index|
      next unless token.type == :CONSTANT && SATELLITE_CONSTANTS.key?(token.value)
      next if nested_in_another_namespace?(all, index)

      [ qualified_from(all, index), token.location.start_line ]
    }
  end

  # A satellite token preceded by `SomeConstant::` is usually a segment of
  # somebody else's path — `Wrapper::CollavreSlack` is Wrapper's own nested
  # constant, not the engine.
  #
  # `Object::` is the one exception, because top-level constants *are* constants
  # of Object: `Object::CollavreGithub::Account` resolves to exactly the same
  # class as `CollavreGithub::Account`. Checked against Ruby rather than
  # reasoned about — `Object::` and a leading `::` both resolve, while
  # `Wrapper::`, `String::` and `Kernel::` all raise NameError. So `Object::` is
  # the whole exception, not the first of a family.
  #
  # The name is built from the satellite token onward, so the qualifier does not
  # survive into the result: the reference is recorded as
  # `CollavreGithub::Account` however it was spelled, and one waiver covers it.
  def nested_in_another_namespace?(all, index)
    return false unless index >= 2
    return false unless all[index - 1].type == :COLON_COLON && all[index - 2].type == :CONSTANT

    !top_level_object?(all, index - 2)
  end

  # True when the token is the real `Object`, i.e. `Object` or `::Object` rather
  # than a nested `Wrapper::Object`.
  def top_level_object?(all, index)
    return false unless all[index].value == "Object"
    return true if index.zero?
    return true unless all[index - 1].type == :COLON_COLON

    index < 2 || all[index - 2].type != :CONSTANT
  end

  def qualified_from(all, index)
    name = all[index].value.dup
    cursor = index + 1
    while all[cursor]&.type == :COLON_COLON && all[cursor + 1]&.type == :CONSTANT
      name << "::" << all[cursor + 1].value
      cursor += 2
    end
    name
  end

  # `belongs_to :account, class_name: "CollavreNotion::NotionAccount"` compiles
  # to a CONSTANT token nowhere, declares nothing in the gemspec, and requires
  # no file — yet the association resolves the class at run time and the core
  # engine breaks when the satellite renames it.
  #
  # Deliberately not keyed on the API that consumes the string. `class_name`,
  # `constantize`, `const_get`, `safe_constantize`, `serialize` and an STI `type`
  # column all resolve one, and enumerating them is the same losing game that
  # produced four rounds of misses on the loader check. A satellite class name
  # written into a string literal in core code is the violation, whatever reads
  # it afterwards.
  def string_references_in(source)
    tokens(source)
      .select { |token| token.type == :STRING_CONTENT }
      .flat_map { |token| token.value.scan(SATELLITE_IN_STRING).map { |name| [ name, token.location.start_line ] } }
  end

  # A constant is not the only way to reach a satellite. Every engine is on the
  # load path via the host Gemfile, so `require "collavre_slack/some_service"`
  # in a core file is a working, undeclared core-to-satellite dependency that
  # names no constant and adds no gemspec entry — invisible to both other
  # checks.
  #
  # The target is read off the call's parsed arguments, not by grepping for the
  # engine name, so prose that happens to mention an engine ("collavre_slack is
  # not loaded" in a warn) is not a violation.
  #
  # This walks the syntax tree rather than the token stream. The token version
  # had to know how many tokens sat between the call and its path, and every
  # formatting variant moved that distance: parentheses pushed the literal from
  # five tokens out to seven, and a call broken across lines put an
  # IGNORED_NEWLINE in the gap that ended the walk before the string. Each was a
  # separate silent miss. Prism has already resolved all of that, so
  # `require(\n  "collavre_slack/foo"\n)` reads the same as the one-liner.
  def requires_in(source)
    loader_calls(Prism.parse(source).value).filter_map { |call|
      next unless loader_receiver?(call)

      string_arguments(call).find { |feature| satellite_for(feature) }
    }.uniq
  end

  def loader_calls(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if node.is_a?(Prism::CallNode) && LOADER_METHODS.include?(node.name.to_s)
    node.compact_child_nodes.each { |child| loader_calls(child, found) }
    found
  end

  # Only literal arguments of the loader itself. `require_relative
  # File.join(__dir__, "collavre_slack")` computes its path, so the engine name
  # sits in an argument to `File.join` rather than to the loader, and this
  # returns nothing for it — deliberately, since that is also how a false
  # positive on an unrelated nested call would arise.
  #
  # The static parts of an interpolated string count: the engine name in
  # "#{root}/collavre_slack/foo" is still a literal reference to it.
  def string_arguments(call)
    call.arguments&.arguments.to_a.flat_map do |argument|
      case argument
      when Prism::StringNode then argument.unescaped
      when Prism::InterpolatedStringNode then argument.parts.grep(Prism::StringNode).map(&:unescaped)
      else []
      end
    end
  end

  # The receiver rule differs by method, because the methods differ.
  #
  # `autoload` is `Module#autoload`, and a module receiver is its ordinary form:
  # `Collavre.autoload :Notion, "collavre_notion/foo"` registers the constant
  # and loads that file on first reference — a real dependency that names no
  # satellite constant and adds no gemspec entry. Restricting it to Kernel would
  # miss the common spelling and catch only the rare one.
  #
  # `require` and `load` stay on Kernel. `YAML.load "collavre_slack/x.yml"` is a
  # file read, not a dependency on the engine, and `load` is common enough as a
  # method name that matching any receiver would make this test cry wolf.
  def loader_receiver?(call)
    return true if call.receiver.nil?
    return true if call.name == :autoload

    kernel?(call.receiver)
  end

  # Every spelling that reaches the real Kernel, not just the bare constant.
  # `::Kernel.require "collavre_slack/foo"` parses as a ConstantPathNode rather
  # than a ConstantReadNode, and matching only the latter let a working loader
  # call through on a spelling difference alone.
  #
  # Checked against Ruby rather than reasoned about — `Kernel`, `::Kernel`,
  # `Object::Kernel` and `::Object::Kernel` all load the file, while
  # `Wrapper::Kernel` and `String::Kernel` raise NameError. So the rule is
  # "Kernel, qualified by nothing but Object", which is the same shape as the
  # `Object::` exception the constant detector already makes: top-level
  # constants are constants of Object, and nothing else reaches them.
  def kernel?(node)
    case node
    when Prism::ConstantReadNode then node.name == :Kernel
    when Prism::ConstantPathNode then node.name == :Kernel && top_level_path?(node.parent)
    else false
    end
  end

  # True for the qualifier of a top-level constant: absent (a leading `::`), or
  # `Object` reached the same way. `Wrapper::Object::Kernel` is Wrapper's own
  # nesting and resolves to nothing, so the walk has to reach the root.
  def top_level_path?(node)
    case node
    when nil then true
    when Prism::ConstantReadNode then node.name == :Object
    when Prism::ConstantPathNode then node.name == :Object && top_level_path?(node.parent)
    else false
    end
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
