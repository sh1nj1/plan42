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
  SATELLITE_GEM_NAME = /\Acollavre_/
  SATELLITE_CONSTANT = /\ACollavre[A-Z]\w*\z/
  SATELLITE_IN_SYMBOL = /\bCollavre[A-Z]\w*(?:::[A-Z]\w*)*\b/

  # Every entry point that resolves a path through $LOAD_PATH. `load` and
  # `autoload` are not `require`, but they reach a satellite file just as well
  # and leave behind neither a constant nor a gemspec entry. See
  # #loader_receiver? for why `autoload` is matched on any receiver and the rest
  # only on Kernel.
  LOADER_METHODS = %w[require require_relative require_dependency load autoload].freeze
  CONSTANT_SYMBOL_METHODS = %w[
    autoload? const_defined? const_get const_source_location
    const_set remove_const private_constant public_constant deprecate_constant
  ].freeze
  INHERITED_CONSTANT_LOOKUP_METHODS = %w[
    autoload? const_defined? const_get const_source_location
  ].freeze
  TEMPLATE_RENDER_METHODS = %w[render render_to_string].freeze
  TEMPLATE_RENDER_OPTIONS = %w[template partial file layout].freeze
  ASSET_HELPER_PATH_OPTIONS = {
    "image_tag" => { "srcset" => :srcset },
    "video_tag" => { "poster" => :path }
  }.freeze
  ASSET_HELPER_METHODS = %w[
    asset_path asset_url path_to_asset
    stylesheet_link_tag stylesheet_path stylesheet_url path_to_stylesheet
    javascript_include_tag javascript_path javascript_url path_to_javascript
    image_tag image_path image_url path_to_image picture_tag
    video_tag video_path video_url path_to_video
    audio_tag audio_path audio_url path_to_audio
    font_path font_url path_to_font favicon_link_tag
  ].freeze

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
  SATELLITE_IN_STRING = /\bCollavre[A-Z]\w*(?:::[A-Z]\w*)+\b/
  SATELLITE_ROOT_IN_STRING = /\bCollavre[A-Z]\w*\b(?!::)/

  RUBY_FILE = /\.(rb|rake|erb)(?:\.tt)?\z/

  # The engine ships 247 JavaScript files and script/build.cjs bundles every
  # engine's `app/javascript/*` together, so a core module importing a
  # satellite resolves in this monorepo and breaks a host that installs the
  # core gem on its own. Ruby was the whole scan until now; this is the larger
  # half of what the gemspec packages.
  JS_FILE = /\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)(?:\.(?:erb|tt))*\z/
  CSS_FILE = /\.css(?:\.(?:erb|tt))*\z/
  CSS_ASSET_REFERENCE = /(?:@import\s+(?:url\(\s*)?|url\(\s*)(?:"([^"]+)"|'([^']+)'|([^\s)]+))\s*\)?/i

  # Every static way a JS module names another. Matched on the specifier of the
  # import itself rather than by grepping for the engine name, so a comment or
  # a string that mentions an engine is not a violation — the same rule the
  # Ruby loader detector follows, for the same reason.
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
    dependency_names = core_gemspec.dependencies.map(&:name) + gemspec_dependency_names_in(core_gemspec_source)
    satellite_deps = satellite_gem_dependencies(dependency_names).uniq

    assert_empty satellite_deps,
      "engines/#{CORE}/#{CORE}.gemspec depends on #{satellite_deps.join(', ')} — the core engine cannot require a satellite"
  end

  test "gemspec detector rejects published satellites outside this checkout" do
    assert_equal %w[collavre_salesforce collavre_slack],
      satellite_gem_dependencies(%w[collavre collavre_salesforce collavre_slack])
  end

  test "gemspec detector rejects conditional satellite dependencies" do
    source = <<~RUBY
      Gem::Specification.new do |gemspec|
        gemspec.add_dependency "collavre_windows", ">= 1.0" if Gem.win_platform?
        gemspec.add_runtime_dependency("collavre_macos", "~> 2.0") unless Gem.win_platform?
        add_dependency "collavre_linux" if Gem.win_platform?
        dependency_source.add_dependency "collavre_unrelated"
      end
    RUBY

    assert_equal %w[collavre_linux collavre_macos collavre_windows],
      satellite_gem_dependencies(gemspec_dependency_names_in(source)).sort
  end

  test "gemspec detector scopes its block parameter to the specification block" do
    source = <<~RUBY
      Gem::Specification.new do |gemspec|
        sources.each do |gemspec = nil|
          gemspec.add_dependency "collavre_slack"
        end
      end
    RUBY

    assert_empty satellite_gem_dependencies(gemspec_dependency_names_in(source))
  end

  test "gemspec detector recognizes top-level and optional specification parameters" do
    source = <<~RUBY
      ::Gem::Specification.new do |gemspec|
        gemspec.add_dependency "collavre_windows" if Gem.win_platform?
      end
      Gem::Specification.new do |manifest = nil|
        manifest.add_dependency "collavre_macos" if Gem.mac?
      end
    RUBY

    assert_equal %w[collavre_macos collavre_windows],
      satellite_gem_dependencies(gemspec_dependency_names_in(source)).sort
  end

  test "path detector rejects published satellites outside this checkout" do
    satellite = "collavre_salesforce"
    feature = "#{satellite}/thing"

    assert_equal satellite, satellite_for(feature)
    assert_equal [ feature ], requires_in(%(require "#{feature}"))
    assert_equal [ feature ], js_imports_in(%(import "#{feature}"))
    assert_equal [ feature ], template_paths_in(%(render template: "#{feature}"))
    assert_equal [ feature ], asset_paths_in(%(asset_path "#{feature}"))
    assert_equal [ feature ], css_asset_paths_in(%(@import "#{feature}";))
  end

  test "constant detector rejects published satellites outside this checkout" do
    satellite = "CollavreSalesforce"

    assert_equal [ "#{satellite}::Account" ], names(constant_references_in("#{satellite}::Account.find(1)"))
    assert_equal [ "#{satellite}::Account" ], names(string_references_in(%("#{satellite}::Account".constantize)))
    assert_equal [ satellite ], names(string_references_in(%(Object.const_get("#{satellite}"))))
    assert_equal [ satellite ], names(string_references_in(%("#{satellite}".constantize)))
    assert_equal [ satellite ], names(string_references_in(%(ActiveSupport::Inflector.constantize("#{satellite}"))))
    assert_equal [ satellite ], names(string_references_in(%(belongs_to :account, class_name: "#{satellite}")))
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

  test "detector folds a static string passed to constant resolution" do
    satellite = SATELLITE_CONSTANTS.keys.first
    midpoint = satellite.length / 2
    prefix = satellite[...midpoint]
    suffix = satellite[midpoint..]

    assert_equal [ satellite ], names(string_references_in(%(Object.const_get("#{prefix}" + "#{suffix}"))))
  end

  test "detector folds a static interpolated symbol passed to constant resolution" do
    satellite = SATELLITE_CONSTANTS.keys.first
    midpoint = satellite.length / 2
    prefix = satellite[...midpoint]
    suffix = satellite[midpoint..]

    assert_equal [ satellite ], names(string_references_in(%(Object.const_get(:"#{prefix}\#{"#{suffix}"}"))))
    assert_equal [ satellite ], names(string_references_in(%(Object.const_get(:"#{prefix}\#{:#{suffix}}"))))
    assert_empty names(string_references_in(%(Object.const_get(:"#{prefix}\#{suffix}"))))
  end

  test "detector folds a static string before scanning class references" do
    satellite = SATELLITE_CONSTANTS.keys.first
    midpoint = satellite.length / 2
    prefix = satellite[...midpoint]
    suffix = satellite[midpoint..]

    assert_equal [ "#{satellite}::Account" ],
      names(string_references_in(%(belongs_to :account, class_name: "#{prefix}" + "#{suffix}::Account")))
  end

  test "detector flags a satellite class named by a constant query symbol" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_equal [ satellite ], names(string_references_in("Object.const_get(:#{satellite})"))
    assert_equal [ satellite ], names(string_references_in("Object.const_defined?(:#{satellite})"))
    assert_equal [ satellite ], names(string_references_in("Object.const_source_location(:#{satellite})"))
    assert_equal [ satellite ], names(string_references_in("Object.autoload?(:#{satellite})"))
  end

  test "detector flags a satellite class named by a constant mutator symbol" do
    satellite = SATELLITE_CONSTANTS.keys.first

    %w[const_set remove_const private_constant public_constant deprecate_constant].each do |method|
      assert_equal [ satellite ], names(string_references_in("Object.#{method}(:#{satellite})")), method
    end
  end

  test "detector flags a satellite class named by a reflected constant API symbol" do
    satellite = SATELLITE_CONSTANTS.keys.first

    %w[send public_send __send__].each do |dispatch|
      assert_equal [ satellite ], names(string_references_in("Object.#{dispatch}(:const_get, :#{satellite})")), dispatch
    end
  end

  test "detector flags inherited satellite constant lookup symbols" do
    satellite = SATELLITE_CONSTANTS.keys.first

    %w[autoload? const_defined? const_get const_source_location].each do |method|
      assert_equal [ satellite ], names(string_references_in("Wrapper.#{method}(:#{satellite})")), method
    end
    %w[autoload? const_defined? const_get const_source_location].each do |method|
      assert_empty names(string_references_in("Wrapper.#{method}(:#{satellite}, false)")), method
    end
  end

  test "detector ignores satellite symbols on nested constant mutators" do
    satellite = SATELLITE_CONSTANTS.keys.first

    %w[const_set remove_const private_constant].each do |method|
      assert_empty names(string_references_in("Wrapper.#{method}(:#{satellite})")), method
    end
  end

  test "detector ignores satellite symbols used as ordinary data" do
    satellite = SATELLITE_CONSTANTS.keys.first

    assert_empty names(string_references_in("logger.info(event: :#{satellite})"))
    assert_empty references_in("logger.info(event: :#{satellite})")
  end

  test "string detector resolves Ruby escapes before checking satellite constants" do
    satellite = SATELLITE_CONSTANTS.keys.first
    escaped = satellite.sub(/[A-Z]/) { |letter| "\\u%04X" % letter.ord }

    assert_equal [ "#{satellite}::Account" ], names(string_references_in(%("#{escaped}::Account".constantize)))
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
    assert_empty names(string_references_in(%("CollaborationExtra::Account")))
  end

  test "detector flags a require of a satellite engine" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/some_service" ], requires_in(%(require "#{satellite}/some_service"))
    assert_equal [ satellite ], requires_in(%(require_relative("#{satellite}")))
    assert_equal [ "#{satellite}.rb" ], requires_in(%(require "#{satellite}.rb"))
    assert_equal [ "#{satellite}/some_service" ],
      requires_in(%(require "collavre_" + "#{satellite.delete_prefix('collavre_')}/some_service"))
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

  test "detector flags a direct Kernel loader invoked through self" do
    satellite = SATELLITES.first
    feature = "#{satellite}/some_service"

    assert_equal [ feature ], requires_in(%(self.require "#{feature}"))
    assert_equal [ "#{feature}.rb" ], requires_in(%(self.load "#{feature}.rb"))
  end

  test "detector flags a reflectively invoked Kernel loader" do
    satellite = SATELLITES.first
    feature = "#{satellite}/some_service"

    assert_equal [ feature ], requires_in(%(Kernel.send(:require, "#{feature}")))
    assert_equal [ "#{feature}.rb" ], requires_in(%(::Kernel.public_send(:load, "#{feature}.rb")))
    assert_equal [ feature ], requires_in(%(Kernel.__send__(:require, "#{feature}")))
    assert_equal [ feature ], requires_in(%(Kernel.send("require", "#{feature}")))
    assert_equal [ feature ], requires_in(%(Kernel.method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(Kernel.public_method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(::Kernel.public_method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(Kernel.singleton_method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(::Kernel.singleton_method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(Object.method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(self.method(:require).call("#{feature}")))
    assert_equal [ feature ], requires_in(%(Kernel.method(:require)["#{feature}"]))
    assert_equal [ feature ], requires_in(%(method(:require)["#{feature}"]))
    assert_empty requires_in(%(registry.send(:require, "#{feature}")))
    assert_empty requires_in(%(registry.method(:require).call("#{feature}")))
    assert_empty requires_in(%(registry.public_method(:require).call("#{feature}")))
    assert_empty requires_in(%(registry.singleton_method(:require).call("#{feature}")))
    assert_empty requires_in(%(registry.singleton_method(:autoload).call("#{feature}")))
    assert_empty requires_in(%(Object.public_method(:require).call("#{feature}")))
    assert_empty requires_in(%(self.public_method(:require).call("#{feature}")))
    assert_empty requires_in(%(public_method(:require).call("#{feature}")))
    assert_empty requires_in(%(registry.method(:require)["#{feature}"]))
    assert_empty requires_in(%(Kernel.send(loader_name, "#{feature}")))
  end

  test "detector flags private Kernel loaders reflected through Object" do
    satellite = SATELLITES.first
    feature = "#{satellite}/some_service"

    assert_equal [ feature ], requires_in(%(Object.send(:require, "#{feature}")))
    assert_equal [ feature ], requires_in(%(::Object.__send__(:require, "#{feature}")))
    assert_equal [ feature ], requires_in(%(Object.new.send(:require, "#{feature}")))
    assert_equal [ feature ], requires_in(%(Object.allocate.__send__(:require, "#{feature}")))
    assert_empty requires_in(%(Object.public_send(:require, "#{feature}")))
    assert_empty requires_in(%(Object.new.public_send(:require, "#{feature}")))
    assert_empty requires_in(%(Object.new(:argument).send(:require, "#{feature}")))
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
    assert_equal [ "#{satellite}/foo" ], requires_in(%(Collavre.send(:autoload, :Foo, "#{satellite}/foo")))
    assert_equal [ "#{satellite}/foo" ], requires_in(%(Collavre.method(:autoload).call(:Foo, "#{satellite}/foo")))
  end

  # The path has to belong to the loader itself. A string in a *neighbouring*
  # call on the same line is somebody else's, but a string nested in the
  # loader's argument computes the path it receives and is therefore real.
  test "detector ignores strings belonging to a neighbouring call" do
    satellite = SATELLITES.first

    assert_empty requires_in(%(load(path) || warn("#{satellite} is missing")))
  end

  test "detector flags a satellite nested in a computed loader argument" do
    satellite = SATELLITES.first
    path = "../../#{satellite}/lib/#{satellite}/engine"

    assert_equal [ path ], requires_in(%(require File.join(__dir__, "#{path}")))
    assert_equal [ "#{satellite}/thing" ], requires_in(%(load Pathname.new("#{satellite}/thing")))
  end

  test "detector folds adjacent Ruby loader string literals" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      requires_in(%(require "collavre_" "#{satellite.delete_prefix('collavre_')}/thing"))
  end

  test "detector folds static interpolations in Ruby loader paths" do
    satellite = SATELLITES.first
    suffix = satellite.delete_prefix("collavre_")
    source = <<~RUBY
      require "collavre_\#{"#{suffix}"}/thing"
    RUBY

    assert_equal [ "#{satellite}/thing" ], requires_in(source)
  end

  test "detector flags a satellite template rendered by core" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/integrations/modal" ],
      template_paths_in(%(render template: "#{satellite}/integrations/modal"))
    assert_equal [ "#{satellite}/integrations/modal" ],
      template_paths_in(%(render_to_string "#{satellite}/integrations/modal"))
    assert_equal [ "#{satellite}/integrations/modal" ],
      template_paths_in(%(render(partial: "#{satellite}/integrations/modal")))
    assert_equal [ "#{satellite}/application" ],
      template_paths_in(%(render layout: "#{satellite}/application"))
    assert_equal [ "#{satellite}/integrations/modal" ],
      template_paths_in(%(render "collavre_" + "#{satellite.delete_prefix('collavre_')}/integrations/modal"))
    assert_equal [ "#{satellite}/integrations/modal" ],
      template_paths_in(%(render template: "collavre_" + "#{satellite.delete_prefix('collavre_')}/integrations/modal"))
  end

  test "detector flags a satellite template rendered with a symbol path" do
    satellite = SATELLITES.first
    template = "#{satellite}/integrations/modal"

    assert_equal [ template ], template_paths_in(%(render :"#{template}"))
    assert_equal [ template ], template_paths_in(%(render template: :"#{template}"))
  end

  test "detector flags satellite paths passed to Rails asset helpers" do
    satellite = SATELLITES.first
    path = "#{satellite}/slack_integration"

    %w[stylesheet_link_tag javascript_include_tag image_tag picture_tag asset_path].each do |helper|
      assert_equal [ path ], asset_paths_in(%(#{helper} "#{path}")), helper
    end
    assert_equal [ path ], asset_paths_in(%(stylesheet_link_tag "collavre_" + "#{satellite.delete_prefix('collavre_')}/slack_integration"))
    assert_equal [ path ], asset_paths_in(%(ActionController::Base.helpers.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(ApplicationController.helpers.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(Collavre::ApplicationController.helpers.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(helpers.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(view_context.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(self.helpers.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(self.view_context.asset_path("#{path}")))
    assert_equal [ path ], asset_paths_in(%(image_tag "logo.svg", srcset: { "#{path}" => "2x" }))
    assert_equal [ path ], asset_paths_in(%(video_tag "core.mp4", poster: "#{path}"))
    assert_empty asset_paths_in(%(image_tag "logo.svg", class: "#{path}"))
    assert_empty asset_paths_in(%(image_tag "logo.svg", srcset: { "logo@2x.svg" => "#{path}" }))
    assert_empty asset_paths_in(%(asset_path "logo.svg", srcset: { "#{path}" => "2x" }))
    assert_empty asset_paths_in(%(image_tag "logo.svg", poster: "#{path}"))
    assert_empty asset_paths_in(%(asset_path("https://cdn.example/#{path}")))
    assert_empty asset_paths_in(%(asset_path("//cdn.example/#{path}")))
    assert_equal [ "file:///tmp/#{path}" ], asset_paths_in(%(asset_path("file:///tmp/#{path}")))

    erb_path = ENGINES_ROOT.join(CORE, "app/views/collavre/example.html.erb")
    assert_includes ruby_violations_in(erb_path.to_s, erb_template_ruby_source(%(<%= stylesheet_link_tag "#{path}" %>))),
      "  engines/#{CORE}/app/views/collavre/example.html.erb references asset \"#{path}\" (engines/#{satellite})"
  end

  test "asset path detector ignores similarly named methods on arbitrary objects" do
    satellite = SATELLITES.first

    assert_empty asset_paths_in(%(registry.image_tag("#{satellite}/slack_integration")))
    assert_empty asset_paths_in(%(registry.picture_tag("#{satellite}/slack_integration")))
  end

  test "detector flags satellite asset paths in packaged CSS" do
    satellite = SATELLITES.first
    path = "#{satellite}/slack_integration.css"
    css_path = ENGINES_ROOT.join(CORE, "app/assets/stylesheets/collavre/application.css")

    assert_equal [ path ], css_asset_paths_in(%(@import "#{path}";))
    assert_equal [ path ], css_asset_paths_in(%(@import url("#{path}");))
    assert_equal [ path ], css_asset_paths_in(%(.integration { background: url("#{path}") }))
    assert_empty css_asset_paths_in(%(/* url("#{path}") */))
    assert_empty css_asset_paths_in(%(.notice { content: "url(#{path})" }))
    assert_empty css_asset_paths_in(%(.integration { background: url("https://cdn.example/#{path}") }))
    assert_empty css_asset_paths_in(%(.integration { background: url("//cdn.example/#{path}") }))
    assert_equal [ "file:///tmp/#{path}" ], css_asset_paths_in(%(.integration { background: url("file:///tmp/#{path}") }))
    assert_includes css_violations_in(css_path.to_s, %(@import "#{path}";)),
      "  engines/#{CORE}/app/assets/stylesheets/collavre/application.css references asset \"#{path}\" (engines/#{satellite})"

    erb_path = css_path.sub_ext(".css.erb")
    assert_includes css_violations_in(erb_path.to_s, %(<% require "#{satellite}/thing" %>)),
      "  engines/#{CORE}/app/assets/stylesheets/collavre/application.css.erb requires \"#{satellite}/thing\" (engines/#{satellite})"

    template_path = css_path.sub_ext(".css.tt")
    assert_includes css_violations_in(template_path.to_s, %(<% require "#{satellite}/thing" %>)),
      "  engines/#{CORE}/app/assets/stylesheets/collavre/application.css.tt requires \"#{satellite}/thing\" (engines/#{satellite})"
  end

  test "template detector ignores ordinary rendered data" do
    satellite = SATELLITES.first

    assert_empty template_paths_in(%(render json: { error: "#{satellite}/not_a_template" }))
  end

  test "template detector ignores non-Rails renderers" do
    satellite = SATELLITES.first

    assert_empty template_paths_in(%(template.render("#{satellite}/example")))
  end

  test "template detector recognizes explicit Rails render receivers" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/example" ], template_paths_in(%(controller.render("#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ], template_paths_in(%(ApplicationController.render("#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ], template_paths_in(%(ActionController::Base.render(template: "#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ], template_paths_in(%(ApplicationController.renderer.render(template: "#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ], template_paths_in(%(ActionController::Base.renderer.render(template: "#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ],
      template_paths_in(%(ApplicationController.renderer.new(http_host: "example.test").render(template: "#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ],
      template_paths_in(%(ApplicationController.renderer.with_defaults(http_host: "example.test").render(template: "#{satellite}/example")))
    assert_equal [ "#{satellite}/example" ],
      template_paths_in(<<~RUBY)
        ApplicationController.renderer.with_defaults(
          http_host: "example.test"
        ).render(template: "#{satellite}/example")
      RUBY
    assert_equal [ "#{satellite}/example" ],
      template_paths_in(%(self.view_context.render(template: "#{satellite}/example")))
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
  # interpolated string counts. Only the reserved `collavre_` prefix identifies
  # a satellite; unrelated path segments must remain ordinary data.
  test "detector flags an interpolated satellite path and ignores unrelated paths" do
    satellite = SATELLITES.first

    assert_equal [ "/#{satellite}/foo" ], requires_in(%(require "\#{root}/#{satellite}/foo"))
    assert_empty requires_in(%(require "\#{root}/collaboration_stub/foo"))
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

  # The scan was Ruby-only while the gemspec packaged more JavaScript than
  # Ruby, so this pins the count rather than mere presence: dropping the
  # extension or an extensionless Node entry point would leave shipped code
  # unread.
  test "core source scan covers the JavaScript the engine ships" do
    scanned = core_sources.count { |path| javascript_source?(path) }
    root = ENGINES_ROOT.join(CORE)
    packaged = core_gemspec.files.count { |path| javascript_source?(root.join(path).to_s) }

    assert_operator scanned, :>, 100,
      "core engine scan found #{scanned} JS files — script/build.cjs bundles them, so they are shipped code"
    assert_equal packaged, scanned
    assert_includes core_sources, root.join("skills/collavre/scripts/collavre").to_s
    assert_includes core_sources, root.join("lib/generators/collavre/install/templates/build.cjs.tt").to_s
  end

  test "TypeScript sources are scanned as JavaScript modules" do
    %w[entry.ts view.tsx entry.mts entry.cts entry.ts.tt view.tsx.tt entry.mts.tt entry.cts.tt].each do |path|
      assert javascript_source?(path), "#{path} is a shipped module source"
    end
  end

  test "JavaScript ERB templates retain static imports outside ERB directives" do
    satellite = SATELLITES.first
    path = ENGINES_ROOT.join(CORE, "app/javascript/entry.js.erb").to_s
    source = <<~ERB
      <% if enabled? %>
      import Thing from "#{satellite}/thing"
      <% end %>
    ERB

    assert javascript_source?(path, source)
    assert_equal [ "  engines/#{CORE}/app/javascript/entry.js.erb imports \"#{satellite}/thing\" (engines/#{satellite})" ],
      js_violations_in(path, source)
    assert_empty js_violations_in(path, %(<%= import("#{satellite}/thing") %>))
    assert_equal [ "  engines/#{CORE}/app/javascript/entry.js.erb requires \"#{satellite}/thing\" (engines/#{satellite})" ],
      js_violations_in(path, %(<% require "#{satellite}/thing" %>))
  end

  test "JavaScript generator templates scan ERB directives as Ruby" do
    satellite = SATELLITES.first
    path = ENGINES_ROOT.join(CORE, "lib/generators/collavre/install/templates/build.cjs.tt").to_s
    source = <<~ERB
      <% require "#{satellite}/generator" %>
      module.exports = {};
    ERB

    assert javascript_source?(path, source)
    assert_equal [ "  engines/#{CORE}/lib/generators/collavre/install/templates/build.cjs.tt requires \"#{satellite}/generator\" (engines/#{satellite})" ],
      js_violations_in(path, source)
  end

  test "Ruby and Rake generator templates are scanned as Ruby sources" do
    %w[initializer.rb.tt task.rake.tt].each do |path|
      assert ruby_source?(path), "#{path} is a shipped Ruby source template"
    end
  end

  test "Ruby generator templates retain static loader calls around ERB output" do
    satellite = SATELLITES.first
    source = <<~RUBY
      module <%= class_name %>
        require "#{satellite}/install"
      end
    RUBY

    assert_equal [ "#{satellite}/install" ], requires_in(ruby_generator_template_source(source))
  end

  test "TSX generator templates use JSX scanning" do
    satellite = SATELLITES.first
    path = ENGINES_ROOT.join(CORE, "lib/generators/collavre/install/templates/view.tsx.tt")

    assert_empty js_violations_in(path.to_s, %(<div>import "#{satellite}/thing"</div>))
  end

  test "detector flags a satellite imported from core JavaScript" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ], js_imports_in(%(import Thing from "#{satellite}/thing";))
    assert_equal [ "../../../#{satellite}/app/javascript/thing" ],
      js_imports_in(%(import { a, b } from "../../../#{satellite}/app/javascript/thing";))
  end

  test "detector flags every static form a JS module can name another by" do
    satellite = SATELLITES.first
    escaped_satellite = satellite.sub("_", "\\\\u005f")
    hexadecimal_satellite = satellite.sub("_", "\\\\x5f")
    braced_satellite = satellite.sub("_", "\\\\u{5f}")
    {
      %(import "#{satellite}/side_effect";) => "#{satellite}/side_effect",
      %(export { thing } from "#{satellite}/thing";) => "#{satellite}/thing",
      %(const t = require("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require.resolve("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require.resolve?.("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require["resolve"]("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require?.resolve("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require?.["resolve"]("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require.resolve.call(require, "#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require.resolve.apply(require, ["#{satellite}/thing"]);) => "#{satellite}/thing",
      %(const t = require.resolve.bind(require)("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = module["require"]["resolve"]("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta.resolve("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta["resolve"]("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta?.resolve("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta?.["resolve"]("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta.resolve.call(import.meta, "#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta.resolve["call"](import.meta, "#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = import.meta.resolve.apply(import.meta, ["#{satellite}/thing"]);) => "#{satellite}/thing",
      %(const t = import.meta.resolve["apply"](import.meta, ["#{satellite}/thing"]);) => "#{satellite}/thing",
      %(const t = await import("#{satellite}/thing");) => "#{satellite}/thing",
      %(const t = require("collavre_" + "#{satellite.delete_prefix('collavre_')}/thing");) => "#{satellite}/thing",
      %(const t = await import("collavre_" + "#{satellite.delete_prefix('collavre_')}/thing");) => "#{satellite}/thing",
      %(const t = require("collavre_" + ("#{satellite.delete_prefix('collavre_')}/thing"));) => "#{satellite}/thing",
      %(const t = await import(("collavre_" + "#{satellite.delete_prefix('collavre_')}/thing"));) => "#{satellite}/thing",
      %(const t = await import(`#{satellite}/thing`);) => "#{satellite}/thing",
      %(import Thing from "#{escaped_satellite}/thing";) => "#{satellite}/thing",
      %(const t = await import(`#{escaped_satellite}/thing`);) => "#{satellite}/thing",
      %(import Thing from "#{hexadecimal_satellite}/thing";) => "#{satellite}/thing",
      %(import Thing from "#{braced_satellite}/thing";) => "#{satellite}/thing",
      %(import {\n  a,\n  b\n} from "#{satellite}/thing";) => "#{satellite}/thing"
    }.each do |source, expected|
      assert_equal [ expected ], js_imports_in(source), "missed #{source.inspect}"
    end
  end

  test "detector scans imports evaluated inside template literal expressions" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const value = `${import("#{satellite}/thing")}`;))
    assert_empty js_imports_in(%(const example = `import "#{satellite}/thing"`;))
  end

  test "detector folds static template literal interpolations" do
    satellite = SATELLITES.first
    suffix = satellite.delete_prefix("collavre_")

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const value = require(`collavre_${"#{suffix}"}/thing`);))
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const value = import(`collavre_${("#{suffix[0...1]}" + "#{suffix[1..]}")}/thing`);))
    assert_empty js_imports_in(%(const value = import(`collavre_${suffix}/thing`);))
  end

  test "detector scans imports after an interpolated template literal" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const ratio = `${() => {}}` / import("#{satellite}/thing");))
  end

  test "detector scans imports after an object literal following a declaration" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(class X {}; const ratio = {} / import("#{satellite}/thing")))
  end

  test "detector scans imports after function expressions" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const ratio = function() {} / import("#{satellite}/thing") / value))
  end

  test "detector ignores regex literals after bindingless catch blocks" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(try {} catch {}\n/import("#{satellite}\\/thing")/.test(text)))
  end

  test "detector ignores regex literals after extends" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(class X extends /import("#{satellite}\\/thing")/.constructor {}))
  end

  test "detector scans imports after an extends property" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const receiver = { extends: 8 }; const value = receiver.extends / import("#{satellite}/thing") / 2))
  end

  test "detector scans imports after a property keyword" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const value = receiver.return / import("#{satellite}/thing") / 2))
  end

  test "detector ignores regex literals after a spread operator" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(fn(.../import "#{satellite}\\/thing"/.exec(text));))
  end

  test "detector scans imports after a TypeScript postfix non-null assertion" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const ratio = value! / (import("#{satellite}/thing"), 1);))
  end

  # Same rule the Ruby loader detector follows: the specifier is the violation,
  # not the engine name appearing somewhere in the file.
  test "detector ignores a satellite named outside a JS import" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(// see #{satellite}/thing for the pattern))
    assert_empty js_imports_in(%(console.warn("#{satellite} is not loaded");))
    assert_empty js_imports_in(%(import Thing from "#{CORE}/thing";))
    assert_empty js_imports_in(%(import(`#{satellite}/\${name}`);))
    assert_empty js_imports_in(%(import Thing from "./components/thing";))
    assert_empty js_imports_in(%(// import "#{satellite}/thing"\n))
    assert_empty js_imports_in(%(/* import "#{satellite}/thing" */))
    assert_empty js_imports_in(%(const example = 'import "#{satellite}/thing";))
    assert_empty js_imports_in(%(function matches() { return ! /import "#{satellite}\/thing"/.test(text) }))
    assert_empty js_imports_in(%(const pattern = /import "#{satellite}\/thing"/;))
    assert_empty js_imports_in(%(if (ready) /import "#{satellite}\/thing"/.test(text);))
    assert_empty js_imports_in(%(if (ready) {}\n/import "#{satellite}\/thing"/.test(text)))
    assert_empty js_imports_in(%(if (ready) {} else /import "#{satellite}\/thing"/.test(text);))
    assert_empty js_imports_in(%(do /import "#{satellite}\/thing"/.test(text); while (ready);))
    assert_empty js_imports_in(%(function* matches() { yield /import "#{satellite}\/thing"/ }))
    assert_empty js_imports_in(%(class Example {}\n/import "#{satellite}\/thing"/.test(text)))
    assert_empty js_imports_in(%(interface Example {}\n/import "#{satellite}\/thing"/.test(text)))
    assert_empty js_imports_in(%(export default /import "#{satellite}\/thing"/))
    assert_empty js_imports_in(%(for (const char of /import "#{satellite}\/thing"/.source) {}))
    assert_empty js_imports_in(%(function matches() {}\n/import "#{satellite}\/thing"/.test(text)))
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const ratio = object.of / import("#{satellite}/thing")))
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const ratio = count++ / import("#{satellite}/thing")))
  end

  test "detector ignores import examples in JSX text while keeping JSX expressions" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(<code>import "#{satellite}/thing"</code>), jsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(<code>{import("#{satellite}/thing")}</code>), jsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(<code>{ready ? "}" : import("#{satellite}/thing")}</code>), jsx: true)
    assert_empty js_imports_in(%(<>import "#{satellite}/thing"</>), jsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(<>{import("#{satellite}/thing")}</>), jsx: true)
    assert_empty js_imports_in(%(<div>{ready && <code>import "#{satellite}/thing"</code>}</div>), jsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(<div>{ready && <code>{import("#{satellite}/thing")}</code>}</div>), jsx: true)
  end

  test "detector masks JSX children in components named with valid identifier starts" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(<_Code>import "#{satellite}/thing"</_Code>), jsx: true)
    assert_empty js_imports_in(%(<$Code>import "#{satellite}/thing"</$Code>), jsx: true)
  end

  test "detector scans module syntax after JSX tag delimiters" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const view = <div>hello</div>; import("#{satellite}/thing")), jsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(<div title={"x\\\""}>hello</div>; import("#{satellite}/thing")), jsx: true)
  end

  test "TSX generic arrows do not mask later module syntax as JSX text" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const id = <T,>(value: T) => value; import("#{satellite}/thing")), jsx: true, tsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const id = <T extends object>(value: T) => value; import("#{satellite}/thing")), jsx: true, tsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const id = <T = object>(value: T) => value; import("#{satellite}/thing")), jsx: true, tsx: true)
  end

  test "TSX generic declarations do not mask later module syntax as JSX text" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(function identity<T>(value: T) { return value }\nimport("#{satellite}/thing")), jsx: true, tsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(export async function identity<T extends object>(value: T): Promise<T> { return value }\nimport("#{satellite}/thing")), jsx: true, tsx: true)
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(class Box { identity<T>(value: T): T { return value }\n}\nimport("#{satellite}/thing")), jsx: true, tsx: true)
    # A single-parameter generic is still a JSX element when it wraps children.
    assert_empty js_imports_in(%(<T>import "#{satellite}/thing"</T>), jsx: true, tsx: true)
  end

  # Masking is the dangerous direction: anything a mis-read tag swallows never
  # reaches the scanner. An opening tag with no closing tag anywhere after it is
  # not valid JSX, so it is a misdetection — leave the source alone and let the
  # tokenizer see it rather than blanking the rest of the file.
  test "an unclosed JSX tag does not mask the rest of the source" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in(%(const bound = a <Widget> b;\nimport("#{satellite}/thing")), jsx: true)
    assert_empty js_imports_in(%(<Widget>import "#{satellite}/thing"</Widget>), jsx: true)
  end

  test "detector ignores an import method called on an object" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(registry.import("#{satellite}/template")))
    assert_empty js_imports_in(%(registry.import.meta.resolve("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(import("#{satellite}/template")))
  end

  test "detector ignores a require method called on an object" do
    satellite = SATELLITES.first

    assert_empty js_imports_in(%(registry.require("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require.call(null, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require["call"](null, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require.apply(null, ["#{satellite}/template"])))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require["apply"](null, ["#{satellite}/template"])))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require.bind(null)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require.bind(null, "#{satellite}/template")()))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require["bind"](null)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.bind(null)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.["bind"](null)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module.require("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module.require.bind(module)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"]("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"].call(module, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"]["call"](module, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"].apply(module, ["#{satellite}/template"])))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"]["apply"](module, ["#{satellite}/template"])))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"].bind(module)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"]["bind"](module)("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module?.require("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module.require?.("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module?.require?.("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module["require"]?.("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(module?.["require"]("#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.call(null, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.["call"](null, "#{satellite}/template")))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.apply(null, ["#{satellite}/template"])))
    assert_equal [ "#{satellite}/template" ], js_imports_in(%(require?.["apply"](null, ["#{satellite}/template"])))
    assert_equal [ "//tmp/#{satellite}/template" ], js_imports_in(%(require("//tmp/#{satellite}/template")))
    assert_equal [ "file:///tmp/#{satellite}/template" ], js_imports_in(%(import("file:///tmp/#{satellite}/template")))
    assert_empty js_imports_in(%(registry.module.require("#{satellite}/template")))
    assert_empty js_imports_in(%(registry.module["require"]("#{satellite}/template")))
    assert_empty js_imports_in(%(registry.module["require"].call(module, "#{satellite}/template")))
    assert_empty js_imports_in(%(registry.module["require"].apply(module, ["#{satellite}/template"])))
    assert_empty js_imports_in(%(registry.module?.require("#{satellite}/template")))
    assert_empty js_imports_in(%(registry.require.call(null, "#{satellite}/template")))
    assert_empty js_imports_in(%(registry.require.apply(null, ["#{satellite}/template"])))
    assert_empty js_imports_in(%(registry.require.bind(null)("#{satellite}/template")))
    assert_empty js_imports_in(%(require.bind(null, "local/path")("#{satellite}/template")))
  end

  test "JS specifier decoder removes escaped line terminators" do
    satellite = SATELLITES.first

    assert_equal [ "#{satellite}/thing" ],
      js_imports_in("import X from \"#{satellite.sub("_", "_\\\n")}/thing\"")
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in("import X from \"#{satellite.sub("_", "_\\\r\n")}/thing\"")
    assert_equal [ "#{satellite}/thing" ],
      js_imports_in("import X from \"#{satellite.sub("_", "_\\\r")}/thing\"")
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

  # #references_in orders by line so that #unwaived blames the newest occurrence
  # of a name. That only works if both detectors report a real line — a string
  # reference reporting nil sorts as 0 and jumps ahead of every constant above
  # it, which is exactly what a shadowed helper caused here.
  test "string references carry their source line and sort with constant ones" do
    satellite = SATELLITE_CONSTANTS.keys.first
    source = "#{satellite}::Account.first\nbelongs_to :a, class_name: \"#{satellite}::Repository\"\n"

    assert_equal [ [ "#{satellite}::Repository", 2 ] ], string_references_in(source)
    assert_equal [ [ "#{satellite}::Account", :constant ], [ "#{satellite}::Repository", :string ] ],
      references_in(source)
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
    packaged = core_gemspec.files.select do |path|
      ruby_source?(path) || javascript_source?(root.join(path).to_s) || css_source?(path) || File.basename(path) == "Rakefile"
    end

    # The gemspec does not package itself, and it is Ruby that can require.
    (packaged.map { |path| root.join(path).to_s } << root.join("#{CORE}.gemspec").to_s).select { |path| File.file?(path) }
  end

  def core_gemspec
    @core_gemspec ||= Gem::Specification.load(ENGINES_ROOT.join(CORE, "#{CORE}.gemspec").to_s)
  end

  def core_gemspec_source
    File.read(ENGINES_ROOT.join(CORE, "#{CORE}.gemspec"))
  end

  def violations_in(path)
    source = File.read(path)
    return js_violations_in(path, source) if javascript_source?(path, source)
    return css_violations_in(path, source) if css_source?(path)

    # ERB views are not Ruby, so lex only the fragments between their tags.
    # Ruby generator templates are Ruby with ERB placeholders, so retain their
    # static source and replace output tags with a syntactically valid value.
    ruby = ruby_source_for(path, source)
    ruby_violations_in(path, ruby)
  end

  def ruby_violations_in(path, source)
    # Requires are deliberately absent from the waiver: no core file has one
    # today, and a new one is never the frozen-migration case the list exists
    # for.
    known = KNOWN_VIOLATIONS.fetch(relative(path), [])

    unwaived(references_in(source), known).map { |name, kind|
      phrasing = kind == :string ? "names #{name} in a string" : "references #{name}"
      "  #{relative(path)} #{phrasing} (engines/#{engine_for(name)})"
    } + requires_in(source).map { |feature|
      "  #{relative(path)} requires \"#{feature}\" (engines/#{satellite_for(feature)})"
    } + template_paths_in(source).map { |template|
      "  #{relative(path)} renders template \"#{template}\" (engines/#{satellite_for(template)})"
    } + asset_paths_in(source).map { |asset|
      "  #{relative(path)} references asset \"#{asset}\" (engines/#{satellite_for(asset)})"
    }
  end

  def js_violations_in(path, source)
    template = path.end_with?(".tt") || path.delete_suffix(".tt").end_with?(".erb")
    extension = File.extname(path.delete_suffix(".tt").delete_suffix(".erb"))
    javascript = template ? javascript_erb_template_source(source) : source
    violations = js_imports_in(javascript, jsx: %w[.jsx .tsx].include?(extension), tsx: extension == ".tsx").map do |specifier|
      "  #{relative(path)} imports \"#{specifier}\" (engines/#{satellite_for(specifier)})"
    end
    violations + (template ? ruby_violations_in(path, erb_template_ruby_source(source)) : [])
  end

  def css_violations_in(path, source)
    template = path.end_with?(".tt") || path.delete_suffix(".tt").end_with?(".erb")
    css = template ? javascript_erb_template_source(source) : source
    violations = css_asset_paths_in(css).map do |asset|
      "  #{relative(path)} references asset \"#{asset}\" (engines/#{satellite_for(asset)})"
    end
    return violations unless template

    violations + ruby_violations_in(path, erb_template_ruby_source(source))
  end

  def ruby_source_for(path, source)
    if path.delete_suffix(".tt").end_with?(".erb")
      erb_template_ruby_source(source)
    elsif path.end_with?(".tt")
      ruby_generator_template_source(source)
    else
      source
    end
  end

  def erb_template_ruby_source(source)
    source.scan(/<%=?-?(.*?)-?%>/m).flatten.join("\n")
  end

  # JavaScript outside ERB tags ships as executable source; the tags themselves
  # are Ruby evaluated at render time. Mask them without shifting line numbers
  # so imports in the static JavaScript remain visible to the token scanner.
  def javascript_erb_template_source(source)
    source.gsub(/<%=?-?.*?-?%>/m) { |directive| directive.gsub(/[^\n]/, " ") }
  end

  def ruby_source?(path)
    path.match?(RUBY_FILE)
  end

  # Generator `.rb.tt` and `.rake.tt` files are Ruby source with ERB embedded
  # in expression positions. Parsing their raw text makes Prism recover past a
  # malformed declaration (for example, `module <%= class_name %>`) and can
  # skip a later loader. Keep control-flow tags as Ruby, discard ERB comments,
  # and substitute output tags with a valid constant while preserving lines.
  def ruby_generator_template_source(source)
    source.gsub(/<%(-?)([=#]?)(.*?)(-?)%>/m) do
      type = Regexp.last_match(2)
      replacement = case type
      when "=" then +"GeneratedTemplateValue"
      when "#" then +""
      else Regexp.last_match(3)
      end
      replacement << "\n" * (Regexp.last_match(0).count("\n") - replacement.count("\n"))
    end
  end

  # The gem packages one extensionless Node executable. Its shebang, not its
  # filename, says it is JavaScript; checking it here keeps a new production
  # CLI on the same boundary rule as app/javascript.
  def javascript_source?(path, source = nil)
    return true if path.match?(JS_FILE)

    head = source || File.binread(path, 256)
    head.b.match?(/\A#![^\n]*\b(?:node|nodejs|deno|bun)(?:\s|\z)/n)
  end

  def css_source?(path)
    path.match?(CSS_FILE)
  end

  # A JS specifier reaches a satellite two ways, and both normalize the same as
  # a Ruby require path: by traversal (`../../collavre_slack/app/javascript/x`)
  # or by package name (`collavre_notion/thing`). #satellite_for already walks
  # every segment of the cleaned path, so neither depth nor spelling matters.
  def js_imports_in(source, jsx: false, tsx: false)
    js_specifiers(js_tokens(jsx ? mask_jsx_text(source, tsx:) : source))
      .select { |specifier| satellite_for(specifier) }
      .uniq
  end

  # JSX child text is neither JavaScript syntax nor an import. Mask it before
  # tokenising, while retaining expressions inside `{...}` where a real dynamic
  # import can appear. This small scanner deliberately only runs for `.jsx`
  # sources; ordinary JavaScript keeps its original token stream.
  def mask_jsx_text(source, tsx: false)
    masked = source.dup
    cursor = 0
    depth = 0

    while cursor < source.length
      if source[cursor] == "<" && (tag = jsx_tag_at(source, cursor, tsx:))
        _name, finish, closing, self_closing = tag
        mask_jsx_tag(source, masked, cursor, finish, tsx:)
        depth -= 1 if closing && depth.positive?
        depth += 1 unless closing || self_closing
        cursor = finish + 1
      elsif depth.positive? && source[cursor] == "{"
        expression_end = jsx_expression_end(source, cursor)
        expression = source[(cursor + 1)...(expression_end - 1)]
        masked[(cursor + 1)...(expression_end - 1)] = mask_jsx_text(expression, tsx:) if expression
        cursor = expression_end
      elsif depth.positive?
        masked[cursor] = " " unless source[cursor] == "\n"
        cursor += 1
      else
        cursor += 1
      end
    end

    masked
  end

  # JSX delimiters are not JavaScript tokens. Leaving `</tag>` in the source
  # lets its slash begin a regex literal and can hide a later import. Attribute
  # expressions remain executable JavaScript, so retain their contents while
  # masking the tag syntax around them.
  def mask_jsx_tag(source, masked, cursor, finish, tsx:)
    while cursor <= finish
      if source[cursor] == "{"
        expression_end = jsx_expression_end(source, cursor)
        expression = source[(cursor + 1)...(expression_end - 1)]
        masked[(cursor + 1)...(expression_end - 1)] = mask_jsx_text(expression, tsx:) if expression
        masked[cursor] = " "
        masked[expression_end - 1] = " "
        cursor = expression_end
      else
        masked[cursor] = " " unless source[cursor] == "\n"
        cursor += 1
      end
    end
  end

  def jsx_tag_at(source, cursor, tsx: false)
    return [ nil, cursor + 1, false, false ] if source[cursor, 2] == "<>" && source[(cursor + 2)..].to_s.include?("</>")
    return [ nil, cursor + 2, true, false ] if source[cursor, 3] == "</>"
    return if tsx && tsx_generic_at?(source, cursor)

    match = source[cursor..].match(/\A<\/?([A-Za-z_$][A-Za-z0-9_$:._-]*)\b/)
    return unless match

    closing = source[cursor + 1] == "/"
    return if !closing && source[cursor + match[0].length] == ","

    finish = jsx_tag_end(source, cursor + match[0].length)
    return unless finish

    self_closing = source[finish - 1] == "/"
    return unless closing || self_closing || closes_later?(source, finish, match[1])

    [ match[1], finish, closing, self_closing ]
  end

  # Masking is the one direction that can hide an import, so a tag only opens a
  # masked region when its closing tag actually exists. An opening tag with no
  # `</name>` after it is not valid JSX — it is something else read as a tag,
  # such as a generic parameter list or a comparison — and blanking the rest of
  # the file on that reading is how a real import escapes the scanner.
  def closes_later?(source, finish, name)
    source[(finish + 1)..].to_s.match?(%r{</#{Regexp.escape(name)}\s*>})
  end

  # In TSX, angle brackets after a name are type parameters, not a JSX element:
  # `<T,>`, `<T extends U>` and `<T = U>` open a generic arrow function, and
  # `<T>` abutting a function or method name opens a generic declaration.
  # Both are recognised by what follows the parameters — an arrow parameter
  # list — so ordinary JSX keeps the normal tag path above.
  def tsx_generic_at?(source, cursor)
    finish = tsx_type_parameter_end(source, cursor)
    return unless finish

    parameters = source[(cursor + 1)...finish]
    rest = source[(finish + 1)..].to_s
    return true if parameters.match?(/,|\bextends\b|=/) && rest.match?(/\A\s*\([^)]*\)(?:\s*:\s*[^=]+)?\s*=>/m)

    source[0...cursor].match?(/[A-Za-z_$][\w$]*\z/) && rest.match?(/\A\s*\([^)]*\)(?:\s*:\s*[^{;=]+)?\s*\{/m)
  end

  def tsx_type_parameter_end(source, cursor)
    depth = 0

    while (character = source[cursor])
      depth += 1 if character == "<"
      if character == ">"
        depth -= 1
        return cursor if depth.zero?
      end
      cursor += 1
    end
  end

  def jsx_tag_end(source, cursor)
    quote = nil
    braces = 0

    while (character = source[cursor])
      if quote
        cursor += 2 and next if character == "\\"
        quote = nil if character == quote
      elsif character == "\"" || character == "'"
        quote = character
      elsif character == "{"
        braces += 1
      elsif character == "}"
        braces -= 1 if braces.positive?
      elsif character == ">" && braces.zero?
        return cursor
      end
      cursor += 1
    end
  end

  # Balancing `{` and `}` is the only thing this needs beyond ordinary scanning,
  # and everything else has to behave exactly as the import scan does — a brace
  # inside a string, a comment or a regex literal is not structural. So it walks
  # the same scanner rather than a second copy of it: the two drifted apart once
  # already, and a quoted "}" ended the expression early.
  def jsx_expression_end(source, cursor)
    depth = 1
    cursor += 1
    tokens = []

    while (character = source[cursor])
      if character == "}"
        depth -= 1
        return cursor + 1 if depth.zero?
      elsif character == "{"
        depth += 1
      end

      cursor = js_scan_token(source, cursor, tokens)
    end

    cursor
  end

  # JS comments and strings can contain a syntactically convincing `import`
  # example. Tokenising the small grammar we need keeps those examples out
  # without depending on a build-time JavaScript parser in a Ruby test.
  def js_tokens(source)
    tokens = []
    cursor = 0
    cursor = js_scan_token(source, cursor, tokens) while cursor < source.length
    tokens
  end

  # One step of that scanner: skip whitespace or a comment, or append exactly one
  # string, regex, word or punctuation token. Returns the cursor after it.
  def js_scan_token(source, cursor, tokens)
    case source[cursor]
    when /\s/ then cursor + 1
    when "/" then js_scan_slash(source, cursor, tokens)
    when "'", "\"" then js_scan_pair(js_string_token(source, cursor), tokens)
    when "`" then js_scan_template(source, cursor, tokens)
    when /[A-Za-z_$]/ then js_scan_word(source, cursor, tokens)
    else
      tokens << [ :punctuation, source[cursor] ]
      cursor + 1
    end
  end

  def js_scan_slash(source, cursor, tokens)
    if source[cursor + 1] == "/"
      source.index("\n", cursor) || source.length
    elsif source[cursor + 1] == "*"
      (source.index("*/", cursor + 2) || source.length - 2) + 2
    elsif js_regex_start?(tokens)
      js_scan_pair(js_regex_token(source, cursor), tokens)
    else
      tokens << [ :punctuation, "/" ]
      cursor + 1
    end
  end

  def js_scan_word(source, cursor, tokens)
    finish = cursor + 1
    finish += 1 while source[finish]&.match?(/[A-Za-z0-9_$]/)
    tokens << [ :word, source[cursor...finish] ]
    finish
  end

  def js_scan_pair(scanned, tokens)
    token, cursor = scanned
    tokens << token
    cursor
  end

  # `/` is division or a regular-expression delimiter depending on its
  # syntactic position. Only a delimiter can hide convincing import syntax, so
  # consume a complete literal when the preceding token can start an
  # expression. A slash after an operand remains punctuation; that preserves
  # real code such as `value / import("collavre_slack/x")`.
  def js_regex_start?(tokens)
    previous = tokens.last
    return true if previous.nil?
    return false if js_postfix_update?(tokens) || js_postfix_non_null_assertion?(tokens)

    expression_starters = [ "(", "[", "{", ",", ":", ";", "=", "!", "?", "+", "-", "*", "%", "&", "|", "^", "~", "<", ">" ]
    return true if previous.first == :punctuation && expression_starters.include?(previous.last)
    return true if js_spread_operator?(tokens)

    return true if control_flow_condition?(tokens)
    return true if js_statement_closing_brace?(tokens)
    return true if js_export_default?(tokens)

    return true if js_class_extends_clause?(tokens)
    return true if previous.first == :word && tokens[-2] != [ :punctuation, "." ] &&
      js_expression_starting_keyword?(previous.last)

    js_for_of_header?(tokens)
  end

  def js_export_default?(tokens)
    tokens.last(2) == [ [ :word, "export" ], [ :word, "default" ] ]
  end

  def js_spread_operator?(tokens)
    tokens.last(3) == Array.new(3, [ :punctuation, "." ])
  end

  # The scanner stores `++` and `--` as two punctuation tokens. After an
  # operand that pair is postfix, so a following slash is division; treating
  # its second character as unary would consume a real dynamic import as regex.
  def js_postfix_update?(tokens)
    operator = tokens.last
    return false unless operator&.first == :punctuation && %w[+ -].include?(operator.last)
    return false unless tokens[-2] == operator

    operand = tokens[-3]
    operand && (operand.first != :punctuation || [ ")", "]", "}" ].include?(operand.last))
  end

  # TypeScript's postfix `!` assertion follows an operand, unlike unary `!`.
  # A following slash is therefore division, so it must not consume a dynamic
  # import as though it began a regex literal.
  def js_postfix_non_null_assertion?(tokens)
    return false unless tokens.last == [ :punctuation, "!" ]

    operand = tokens[-2]
    return false if operand&.first == :word && js_expression_starting_keyword?(operand.last)

    operand && (operand.first != :punctuation || [ ")", "]" ].include?(operand.last))
  end

  def js_expression_starting_keyword?(value)
    %w[return throw case else do yield await void typeof delete new in instanceof].include?(value)
  end

  def js_class_extends_clause?(tokens)
    tokens.last == [ :word, "extends" ] && tokens[-2] != [ :punctuation, "." ]
  end

  def js_for_of_header?(tokens)
    return false unless tokens.last == [ :word, "of" ]

    depth = 0
    tokens.each_index.reverse_each do |index|
      token = tokens[index]
      depth += 1 if token == [ :punctuation, ")" ]
      next unless token == [ :punctuation, "(" ]

      if depth.zero?
        return tokens[index - 1] == [ :word, "for" ] ||
          (tokens[index - 2] == [ :word, "for" ] && tokens[index - 1] == [ :word, "await" ])
      end

      depth -= 1
    end

    false
  end

  def control_flow_condition?(tokens)
    return false unless tokens.last == [ :punctuation, ")" ]

    depth = 0
    tokens.each_index.reverse_each do |index|
      token = tokens[index]
      depth += 1 if token == [ :punctuation, ")" ]
      next unless token == [ :punctuation, "(" ]

      depth -= 1
      return %w[if while for with switch catch].include?(tokens[index - 1]&.last) if depth.zero?
    end
    false
  end

  # A closing brace can end either an operand (`const value = {}`) or a
  # statement block. Only the latter can be followed by a regex literal at the
  # start of the next statement. The scanner need not model every expression;
  # matching the braces and recognising block forms keeps ordinary object
  # division as division while covering function and control-flow bodies.
  def js_statement_closing_brace?(tokens)
    return false unless tokens.last == [ :punctuation, "}" ]

    opening = js_matching_open_brace(tokens)
    opening && js_block_open?(tokens, opening)
  end

  def js_matching_open_brace(tokens)
    depth = 0
    tokens.each_index.reverse_each do |index|
      token = tokens[index]
      depth += 1 if token == [ :punctuation, "}" ]
      next unless token == [ :punctuation, "{" ]

      depth -= 1
      return index if depth.zero?
    end
    nil
  end

  def js_block_open?(tokens, opening)
    before = tokens[opening - 1]
    return true if js_declaration_body?(tokens, opening)
    return true if before&.first == :word && %w[else try catch finally do].include?(before.last)
    return true if tokens[(opening - 2)...opening] == [ [ :punctuation, "=" ], [ :punctuation, ">" ] ]
    return false unless before == [ :punctuation, ")" ]

    parenthesis = js_matching_open_parenthesis(tokens, opening - 1)
    return false unless parenthesis

    head = tokens[parenthesis - 1]&.last
    return true if %w[if while for with switch catch].include?(head)

    js_function_declaration_body?(tokens, parenthesis)
  end

  def js_function_declaration_body?(tokens, parenthesis)
    function = (parenthesis - 1).downto(0).find do |index|
      token = tokens[index]
      break if token.first == :punctuation && %w[; { } ( =].include?(token.last)

      token == [ :word, "function" ]
    end
    return false unless function

    prefix = function - 1
    while prefix >= 0 && js_function_declaration_modifier?(tokens[prefix])
      prefix -= 1
    end

    prefix.negative? || tokens[prefix]&.first == :punctuation && %w[; { }].include?(tokens[prefix].last)
  end

  def js_function_declaration_modifier?(token)
    token.first == :word && %w[export default declare async].include?(token.last)
  end

  def js_declaration_body?(tokens, opening)
    declaration = (opening - 1).downto(0).find do |index|
      token = tokens[index]
      break if token.first == :punctuation && %w[; { }].include?(token.last)

      token.first == :word && %w[class interface enum namespace module].include?(token.last)
    end
    return false unless declaration

    previous = tokens[declaration - 1]
    declaration.zero? ||
      previous&.first == :punctuation && %w[; { }].include?(previous.last) ||
      previous&.first == :word && %w[export default declare abstract public private protected readonly].include?(previous.last)
  end

  def js_matching_open_parenthesis(tokens, closing)
    depth = 0
    closing.downto(0) do |index|
      token = tokens[index]
      depth += 1 if token == [ :punctuation, ")" ]
      next unless token == [ :punctuation, "(" ]

      depth -= 1
      return index if depth.zero?
    end
    nil
  end

  # A regex literal is not module syntax, even when it contains the exact text
  # of an import. Handle escaped delimiters and character classes so the first
  # slash in `/[/] import "collavre_slack/x"/` does not end it early.
  def js_regex_token(source, cursor)
    value = +"/"
    cursor += 1
    in_character_class = false

    while (character = source[cursor])
      value << character
      if character == "\\"
        value << source[cursor + 1].to_s
        cursor += 2
      elsif character == "["
        in_character_class = true
        cursor += 1
      elsif character == "]"
        in_character_class = false
        cursor += 1
      elsif character == "/" && !in_character_class
        cursor += 1
        cursor += 1 while source[cursor]&.match?(/[A-Za-z]/)
        return [ [ :regex, value ], cursor ]
      else
        cursor += 1
      end
    end

    [ [ :regex, value ], cursor ]
  end

  # A template's raw text is data, but each `${...}` body is executable source.
  # Preserve static templates as strings for `import(`path`)`, and scan only the
  # expression bodies of interpolated templates so prose does not become a
  # module reference while dynamic imports still do.
  def js_scan_template(source, cursor, tokens)
    value = +""
    static = true
    cursor += 1

    while (character = source[cursor])
      if character == "\\"
        escaped, cursor = js_escape(source, cursor)
        value << escaped
      elsif character == "`"
        tokens << [ static ? :string : :dynamic_string, value ]
        return cursor + 1
      elsif character == "$" && source[cursor + 1] == "{"
        expression_tokens, cursor = js_template_expression_tokens(source, cursor + 2)
        expression, expression_cursor = js_static_string_expression_at(expression_tokens, 0)
        if expression && expression_cursor == expression_tokens.length
          value << expression
        else
          static = false
          tokens.concat(expression_tokens)
        end
      else
        value << character
        cursor += 1
      end
    end
    tokens << [ :dynamic_string, value ] unless static
    cursor
  end

  # This uses the ordinary token scanner inside an interpolation so comments,
  # regexes and quoted braces retain their JavaScript meaning. Braces only
  # delimit the template expression when they occur as punctuation tokens.
  def js_template_expression_tokens(source, cursor)
    tokens = []
    depth = 1

    while (character = source[cursor])
      if character == "{"
        depth += 1
        tokens << [ :punctuation, character ]
        cursor += 1
      elsif character == "}"
        depth -= 1
        return [ tokens, cursor + 1 ] if depth.zero?

        tokens << [ :punctuation, character ]
        cursor += 1
      elsif character == "`"
        cursor = js_scan_template(source, cursor, tokens)
      else
        cursor = js_scan_token(source, cursor, tokens)
      end
    end

    [ tokens, cursor ]
  end

  def js_string_token(source, cursor)
    quote = source[cursor]
    static = true
    value = +""
    cursor += 1

    while (character = source[cursor])
      if character == "\\"
        escaped, cursor = js_escape(source, cursor)
        value << escaped
      elsif character == quote
        return [ [ static ? :string : :dynamic_string, value ], cursor + 1 ]
      else
        static = false if quote == "`" && character == "$" && source[cursor + 1] == "{"
        value << character
        cursor += 1
      end
    end

    [ [ :dynamic_string, value ], cursor ]
  end

  # Module specifiers are JavaScript strings, not source text: `\\u005f` and
  # `_` both resolve to the same path. Decode the static escape forms here so
  # the boundary rule sees the module Node will actually load. Interpolation
  # stays a dynamic string above and never reaches this method's caller.
  def js_escape(source, cursor)
    escaped = source[cursor + 1]
    return [ "\\", cursor + 1 ] unless escaped
    return [ "", cursor + 3 ] if escaped == "\r" && source[cursor + 2] == "\n"
    return [ "", cursor + 2 ] if escaped == "\n" || escaped == "\r"

    simple = { "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v", "0" => "\0" }
    return [ simple.fetch(escaped, escaped), cursor + 2 ] unless escaped == "u" || escaped == "x"

    if escaped == "u" && source[cursor + 2] == "{"
      close = source.index("}", cursor + 3)
      digits = close && source[(cursor + 3)...close]
      return [ [ digits.to_i(16) ].pack("U"), close + 1 ] if digits&.match?(/\A[\da-fA-F]{1,6}\z/)
    end

    width = escaped == "u" ? 4 : 2
    digits = source[(cursor + 2), width]
    return [ [ digits.to_i(16) ].pack("U"), cursor + 2 + width ] if digits&.match?(/\A[\da-fA-F]{#{width}}\z/)

    [ escaped, cursor + 2 ]
  end

  def js_specifiers(tokens)
    tokens.each_with_index.filter_map do |(kind, value), index|
      if kind == :string && value == "require"
        next js_module_bracket_specifier(tokens, index) if js_module_bracket_loader?(tokens, index)
      end
      next unless kind == :word

      case value
      when "require"
        next unless js_commonjs_loader?(tokens, index)

        js_call_specifier(tokens, index) ||
          js_function_call_specifier(tokens, index) ||
          js_function_apply_specifier(tokens, index) ||
          js_require_resolve_specifier(tokens, index)
      when "import"
        next js_import_meta_resolve_specifier(tokens, index) if js_import_meta_resolve?(tokens, index)
        next if tokens[index - 1] == [ :punctuation, "." ]

        js_bare_import_specifier(tokens, index) || js_call_specifier(tokens, index) || js_from_specifier(tokens, index + 1)
      when "export"
        js_from_specifier(tokens, index + 1)
      end
    end
  end

  # Bare `require()` and Node's `module.require()` load modules. An arbitrary
  # receiver's `require` method is application code and must not block the
  # boundary test; `registry.module.require()` is still arbitrary, not Node's
  # global `module` object.
  def js_commonjs_loader?(tokens, index)
    return true unless tokens[index - 1] == [ :punctuation, "." ]

    receiver = index - 2
    receiver -= 1 if tokens[receiver] == [ :punctuation, "?" ]

    tokens[receiver] == [ :word, "module" ] && tokens[receiver - 1] != [ :punctuation, "." ]
  end

  # `module["require"]` selects the native loader. A bracket selection on any
  # other object remains application code.
  def js_module_bracket_loader?(tokens, index)
    receiver = index - 2
    receiver -= 2 if tokens[receiver] == [ :punctuation, "." ] && tokens[receiver - 1] == [ :punctuation, "?" ]

    tokens[index - 1] == [ :punctuation, "[" ] &&
      tokens[receiver] == [ :word, "module" ] &&
      (receiver.zero? || tokens[receiver - 1] != [ :punctuation, "." ]) &&
      tokens[index + 1] == [ :punctuation, "]" ]
  end

  # A bracket-selected loader supports the same direct, `call`, and `apply`
  # forms as the dot-selected `module.require` loader.
  def js_module_bracket_specifier(tokens, index)
    closing = index + 1

    js_call_specifier(tokens, closing) ||
      js_function_call_specifier(tokens, closing) ||
      js_function_apply_specifier(tokens, closing) ||
      js_require_bound_specifier(tokens, closing) ||
      js_require_resolve_specifier(tokens, closing)
  end

  def js_call_specifier(tokens, index)
    open = js_call_open_at(tokens, index)
    return unless open

    js_static_string_at(tokens, open + 1)
  end

  def js_call_open_at(tokens, index)
    return index + 1 if tokens[index + 1] == [ :punctuation, "(" ]
    index + 3 if tokens[index + 1] == [ :punctuation, "?" ] &&
      tokens[index + 2] == [ :punctuation, "." ] && tokens[index + 3] == [ :punctuation, "(" ]
  end

  def js_require_resolve_specifier(tokens, index)
    resolve = js_function_property_at(tokens, index, "resolve")
    return js_require_bound_specifier(tokens, index) unless resolve

    js_call_specifier(tokens, resolve) ||
      js_function_call_specifier(tokens, resolve) ||
      js_function_apply_specifier(tokens, resolve) ||
      js_require_bound_specifier(tokens, resolve)
  end

  def js_import_meta_resolve?(tokens, index)
    (index.zero? || tokens[index - 1] != [ :punctuation, "." ]) &&
      tokens[index + 1] == [ :punctuation, "." ] &&
      tokens[index + 2] == [ :word, "meta" ] &&
      js_function_property_at(tokens, index + 2, "resolve")
  end

  def js_import_meta_resolve_specifier(tokens, index)
    resolve = js_function_property_at(tokens, index + 2, "resolve")
    js_call_specifier(tokens, resolve) ||
      js_function_call_specifier(tokens, resolve) ||
      js_function_apply_specifier(tokens, resolve)
  end

  # A statically selected native function invoked through `call` retains its
  # original behavior; the first argument only supplies JavaScript's `this`
  # value. Callers establish that the function is a native loader or resolver.
  def js_function_call_specifier(tokens, index)
    call = js_function_property_at(tokens, index, "call")
    return unless call

    open = js_call_open_at(tokens, call)
    comma = open && js_first_call_argument_comma(tokens, open)
    return unless comma

    js_static_string_at(tokens, comma + 1)
  end

  # A statically selected native function invoked through `apply` receives the
  # specifier in its array argument. Only one static specifier is useful to this
  # scanner; computed or multiple arguments stay unknown.
  def js_function_apply_specifier(tokens, index)
    apply = js_function_property_at(tokens, index, "apply")
    return unless apply

    open = js_call_open_at(tokens, apply)
    comma = open && js_first_call_argument_comma(tokens, open)
    return unless comma && tokens[comma + 1] == [ :punctuation, "[" ]

    specifier, close = js_static_string_expression_at(tokens, comma + 2)
    specifier if specifier && tokens[close] == [ :punctuation, "]" ] && tokens[close + 1] == [ :punctuation, ")" ]
  end

  def js_first_call_argument_comma(tokens, opening)
    depths = Hash.new(0)
    pairs = { "(" => ")", "[" => "]", "{" => "}" }

    (opening + 1).upto(tokens.length - 1) do |index|
      token = tokens[index]
      next unless token.first == :punctuation

      value = token.last
      return index if value == "," && depths.values.all?(&:zero?)
      return unless depths["("] == 1 if value == ")"

      if pairs.key?(value)
        depths[value] += 1
      elsif (opening_token = pairs.key(value))
        depths[opening_token] -= 1
      end
    end

    nil
  end

  def js_function_property_at(tokens, index, name)
    if tokens[index + 1] == [ :punctuation, "?" ] && tokens[index + 2] == [ :punctuation, "." ]
      return index + 3 if tokens[index + 3] == [ :word, name ]
      return index + 5 if tokens[index + 3] == [ :punctuation, "[" ] && tokens[index + 4] == [ :string, name ] && tokens[index + 5] == [ :punctuation, "]" ]
    end

    return index + 2 if tokens[index + 1] == [ :punctuation, "." ] && tokens[index + 2] == [ :word, name ]
    index + 3 if tokens[index + 1] == [ :punctuation, "[" ] && tokens[index + 2] == [ :string, name ] && tokens[index + 3] == [ :punctuation, "]" ]
  end

  # `require.bind(this_arg)(specifier)` retains the native CommonJS loader.
  # The bound `this` value cannot change what the loader resolves, so only the
  # statically selected bare or `module.require` forms reach this extractor.
  def js_require_bound_specifier(tokens, index)
    bind = js_function_property_at(tokens, index, "bind")
    return unless bind

    bound_arguments = js_call_open_at(tokens, bind)
    return unless bound_arguments

    closing = js_matching_close_parenthesis(tokens, bound_arguments)
    return unless closing

    return js_static_string_at(tokens, bound_arguments + 3) if tokens[bound_arguments + 2] == [ :punctuation, "," ]

    js_call_specifier(tokens, closing)
  end

  def js_matching_close_parenthesis(tokens, opening)
    depth = 0
    opening.upto(tokens.length - 1) do |index|
      token = tokens[index]
      depth += 1 if token == [ :punctuation, "(" ]
      next unless token == [ :punctuation, ")" ]

      depth -= 1
      return index if depth.zero?
    end
    nil
  end

  def js_static_string_at(tokens, index)
    value, = js_static_string_expression_at(tokens, index)
    value
  end

  def js_static_string_expression_at(tokens, index)
    value, cursor = js_static_string_atom_at(tokens, index)
    return unless value

    while tokens[cursor] == [ :punctuation, "+" ]
      right, cursor = js_static_string_atom_at(tokens, cursor + 1)
      return unless right

      value << right
    end
    [ value, cursor ]
  end

  def js_static_string_atom_at(tokens, index)
    return [ tokens[index].last.dup, index + 1 ] if tokens[index]&.first == :string
    return unless tokens[index] == [ :punctuation, "(" ]

    value, cursor = js_static_string_expression_at(tokens, index + 1)
    return unless value && tokens[cursor] == [ :punctuation, ")" ]

    [ value, cursor + 1 ]
  end

  def js_bare_import_specifier(tokens, index)
    tokens[index + 1].last if tokens[index + 1]&.first == :string
  end

  def js_from_specifier(tokens, start)
    tokens.drop(start).each_with_index do |(kind, value), offset|
      break if kind == :punctuation && value == ";"
      next unless kind == :word && value == "from" && tokens[start + offset + 1]&.first == :string

      return tokens[start + offset + 1].last
    end

    nil
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
    located.each_with_index.sort_by { |(_name, _kind, line), index| [ line || 0, index ] }
      .map { |(name, kind, _line), _index| [ name, kind ] }
  end

  def engine_for(name)
    name.split("::").first.underscore
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
      next unless token.type == :CONSTANT && satellite_constant?(token.value)
      next if symbol_literal?(all, index)
      next if nested_in_another_namespace?(all, index)

      [ qualified_from(all, index), token.location.start_line ]
    }
  end

  # Prism tokenizes `:CollavreSlack` as SYMBOL_BEGIN then CONSTANT. It is data
  # unless a supported constant API consumes it, which is covered by
  # #constant_resolution_literals_in instead of this general constant scanner.
  def symbol_literal?(all, index) = all[index - 1]&.type == :SYMBOL_BEGIN

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
    root = Prism.parse(source).value
    literal_references = located_string_literals_in(root).flat_map do |value, line|
      value.scan(SATELLITE_IN_STRING).map { |name| [ name, line ] }
    end
    resolution_references = constant_resolution_literals_in(root).flat_map do |value, line, kind|
      expression = kind == :symbol ? SATELLITE_IN_SYMBOL : SATELLITE_ROOT_IN_STRING
      value.scan(expression).map { |name| [ name, line ] }
    end
    resolving_root_references = constant_resolving_string_literals_in(root).flat_map do |value, line|
      value.scan(SATELLITE_ROOT_IN_STRING).map { |name| [ name, line ] }
    end

    literal_references + resolution_references + resolving_root_references
  end

  # Prism tokens retain source escapes (`\\u0047`), but Ruby resolves them before
  # code reaches `constantize` or `const_get`. StringNode#unescaped is therefore
  # the value the program will actually use. Interpolated strings expose their
  # static StringNode parts separately, preserving the existing partial-path
  # coverage without treating an expression as literal text.
  #
  # Named apart from #string_literals_in on purpose: the two return different
  # shapes, and while they shared a name Ruby kept only the second definition.
  # Every string reference then came back with a nil line, which #references_in
  # sorts as 0 — so a satellite name in a string was always blamed before a
  # constant reference above it, whatever the file actually said.
  def located_string_literals_in(node, found = [])
    return found unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::StringNode)
      found << [ node.unescaped, node.location.start_line ]
    else
      concatenation = static_string_concatenation(node)
      if concatenation && string_literals_in(node).none? { |value| value.match?(SATELLITE_IN_STRING) }
        found << [ concatenation, node.location.start_line ]
      else
        node.compact_child_nodes.each { |child| located_string_literals_in(child, found) }
      end
    end

    found
  end

  def constant_resolution_literals_in(node, found = [])
    return found unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::CallNode) && constant_symbol_receiver?(node)
      constant_symbol_arguments(node).each { |argument| append_constant_resolution_literal(found, argument) }
    end
    node.compact_child_nodes.each { |child| constant_resolution_literals_in(child, found) }
    found
  end

  def append_constant_resolution_literal(found, argument)
    symbol = static_symbol_concatenation(argument)
    found << [ symbol, argument.location.start_line, :symbol ] if symbol

    string = static_string_concatenation(argument)
    found << [ string, argument.location.start_line, :string ] if string
  end

  def constant_resolving_string_literals_in(node, found = [])
    return found unless node.is_a?(Prism::Node)

    if active_support_inflector_constantize?(node)
      string = static_string_call_argument(node)
      found << [ string, node.location.start_line ] if string
    elsif node.is_a?(Prism::CallNode) && %i[constantize safe_constantize].include?(node.name)
      string = static_string_concatenation(node.receiver)
      found << [ string, node.location.start_line ] if string
    elsif node.is_a?(Prism::AssocNode) && %w[class_name type].include?(association_key_name(node))
      string = static_string_concatenation(node.value)
      found << [ string, node.location.start_line ] if string
    end
    node.compact_child_nodes.each { |child| constant_resolving_string_literals_in(child, found) }
    found
  end

  def association_key_name(node)
    node.key.unescaped if node.key.respond_to?(:unescaped)
  end

  def active_support_inflector_constantize?(node)
    node.is_a?(Prism::CallNode) && %i[constantize safe_constantize].include?(node.name) &&
      node.receiver&.slice&.match?(/\A(?:::)?ActiveSupport::Inflector\z/)
  end

  def static_string_call_argument(node)
    arguments = node.arguments&.arguments
    static_string_concatenation(arguments.first) if arguments&.one?
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

  # A literal satellite template name is the view analogue of `require`: it
  # resolves only while that engine is installed. Limit this to Rails' render
  # APIs and their path-bearing options so an error string in `render json:`
  # remains ordinary data rather than a false dependency.
  def template_paths_in(source)
    render_calls(Prism.parse(source).value).flat_map { |call|
      template_arguments(call).select { |path| satellite_for(path) }
    }.uniq
  end

  # Asset helpers resolve a packaged path just like `render` resolves a view:
  # the core gem can find a satellite asset in this monorepo, but a core-only
  # host cannot. Allow the standard Rails helper receivers in addition to the
  # normal bare ERB spelling, while excluding application objects with a
  # coincidentally named method.
  def asset_paths_in(source)
    asset_helper_calls(Prism.parse(source).value).flat_map { |call|
      call.arguments&.arguments.to_a.flat_map { |argument| asset_path_values(call, argument) }
    }.reject { |path| remote_asset_url?(path) }.select { |path| satellite_for(path) }.uniq
  end

  # CSS imports and URLs resolve through the asset pipeline at runtime. A core
  # stylesheet can therefore find a satellite asset in this monorepo while a
  # core-only host cannot. Strip comments first, then inspect only static CSS
  # path positions rather than arbitrary prose or declaration values.
  def css_asset_paths_in(source)
    source.to_enum(:scan, CSS_ASSET_REFERENCE).filter_map do
      match = Regexp.last_match
      match.captures.compact.first if css_code_position?(source, match.begin(0))
    end
      .reject { |path| remote_asset_url?(path) }
      .select { |path| satellite_for(path) }
      .uniq
  end

  def css_code_position?(source, position)
    quote = nil
    comment = false
    cursor = 0

    while cursor < position
      character = source[cursor]
      if comment
        comment = false if character == "*" && source[cursor + 1] == "/"
      elsif quote
        cursor += 1 if character == "\\"
        quote = nil if character == quote
      elsif character == "/" && source[cursor + 1] == "*"
        comment = true
        cursor += 1
      elsif [ "'", '"' ].include?(character)
        quote = character
      end
      cursor += 1
    end

    !comment && quote.nil?
  end

  def asset_helper_calls(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if rails_asset_helper_call?(node)
    node.compact_child_nodes.each { |child| asset_helper_calls(child, found) }
    found
  end

  def rails_asset_helper_call?(node)
    node.is_a?(Prism::CallNode) && ASSET_HELPER_METHODS.include?(node.name.to_s) &&
      (node.receiver.nil? || rails_asset_helper_receiver?(node.receiver.slice))
  end

  def rails_asset_helper_receiver?(source)
    source.match?(/\A(?:::)?(?:ActionController::Base|(?:[A-Z]\w*::)*ApplicationController)\.helpers\z|\A(?:self\.)?(?:helpers|view_context)\z/)
  end

  def asset_path_values(call, node)
    return asset_helper_option_values(call, node) if node.is_a?(Prism::KeywordHashNode)

    template_path_values(node)
  end

  def asset_helper_option_values(call, node)
    path_options = ASSET_HELPER_PATH_OPTIONS[call.name.to_s]
    return [] unless path_options

    node.elements.flat_map do |association|
      next [] unless association.is_a?(Prism::AssocNode)
      option_type = path_options[association_key_name(association)]
      next [] unless option_type

      option_type == :srcset ? srcset_path_values(association.value) : template_path_values(association.value)
    end
  end

  def srcset_path_values(node)
    return template_path_values(node) unless node.is_a?(Prism::HashNode)

    node.elements.filter_map do |association|
      template_path_values(association.key) if association.is_a?(Prism::AssocNode)
    end.flatten
  end

  def render_calls(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if rails_render_call?(node)
    node.compact_child_nodes.each { |child| render_calls(child, found) }
    found
  end

  # Bare calls and conventional controller receivers use Rails' view API. A
  # method named `render` on an arbitrary receiver (for example a Liquid
  # template) receives data rather than a Rails template path.
  def rails_render_call?(node)
    return false unless node.is_a?(Prism::CallNode) && TEMPLATE_RENDER_METHODS.include?(node.name.to_s)

    receiver = node.receiver
    receiver.nil? || rails_render_receiver?(receiver.slice)
  end

  def rails_render_receiver?(source)
    source.match?(/\A(?:::)?(?:ActionController::Base|(?:[A-Z]\w*::)*ApplicationController)\z|(?:\A|::)\w*Controller\z|\A(?:controller|view_context|self|self\.view_context)\z/) ||
      source.match?(/\A(?:::)?(?:ActionController::Base|(?:[A-Z]\w*::)*ApplicationController)\.renderer(?:\.(?:new|with_defaults)\(.*\))?\z|(?:\A|::)\w*Controller\.renderer(?:\.(?:new|with_defaults)\(.*\))?\z/m)
  end

  def template_arguments(call)
    call.arguments&.arguments.to_a.flat_map do |argument|
      case argument
      when Prism::StringNode, Prism::SymbolNode, Prism::InterpolatedStringNode, Prism::CallNode
        template_path_values(argument)
      when Prism::KeywordHashNode
        argument.elements.flat_map do |association|
          next [] unless association.is_a?(Prism::AssocNode)
          next [] unless TEMPLATE_RENDER_OPTIONS.include?(association.key&.unescaped)

          template_path_values(association.value)
        end
      else []
      end
    end
  end

  def template_path_values(node)
    return [ node.unescaped ] if node.is_a?(Prism::SymbolNode)

    static_string_concatenation(node) || string_literals_in(node)
  end

  def loader_calls(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if node.is_a?(Prism::CallNode) && loader_method(node)
    node.compact_child_nodes.each { |child| loader_calls(child, found) }
    found
  end

  # `Kernel.send(:require, path)`, `Kernel.public_send(:load, path)`, and
  # `Kernel.__send__(:require, path)` invoke the same loaders as direct calls.
  # Limit this to static symbols or strings so a dynamic dispatch is not
  # mistaken for a dependency that cannot be known statically.
  def loader_method(call)
    direct_loader_method(call) || reflected_loader_method(call) || method_object_loader_method(call)
  end

  def direct_loader_method(call)
    call.name.to_s if LOADER_METHODS.include?(call.name.to_s)
  end

  def reflected_loader_method(call)
    return unless %w[send public_send __send__].include?(call.name.to_s)

    method_name = call.arguments&.arguments&.first
    return unless method_name.is_a?(Prism::SymbolNode) || method_name.is_a?(Prism::StringNode)

    method_name.unescaped if LOADER_METHODS.include?(method_name.unescaped)
  end

  def constant_symbol_method(call)
    return call.name.to_s if CONSTANT_SYMBOL_METHODS.include?(call.name.to_s)
    return unless %w[send public_send __send__].include?(call.name.to_s)

    method_name = call.arguments&.arguments&.first
    return unless method_name.is_a?(Prism::SymbolNode) || method_name.is_a?(Prism::StringNode)

    method_name.unescaped if CONSTANT_SYMBOL_METHODS.include?(method_name.unescaped)
  end

  def constant_symbol_arguments(call)
    arguments = call.arguments&.arguments.to_a
    constant_symbol_method(call) == call.name.to_s ? arguments : arguments.drop(1)
  end

  # A class's default constant lookup follows its ancestors, which reaches
  # Object's top-level constants. Mutators always target the receiver's own
  # namespace, while an explicit false disables inherited lookup.
  def constant_symbol_receiver?(call)
    method = constant_symbol_method(call)
    return false unless method
    return true if top_level_object_receiver?(call.receiver)
    return false unless INHERITED_CONSTANT_LOOKUP_METHODS.include?(method)

    !constant_symbol_arguments(call)[1].is_a?(Prism::FalseNode)
  end

  # A statically selected `Kernel.method(:require).call(path)`,
  # `Kernel.public_method(:require).call(path)`,
  # `Kernel.singleton_method(:require).call(path)`,
  # `Object.method(:require).call(path)`, `self.method(:require).call(path)`,
  # or `method(:require).call(path)` invokes the native loader just like direct
  # and reflective dispatch. Object inherits Kernel's private loaders;
  # arbitrary receivers stay excluded.
  def method_object_loader_method(call)
    return unless %i[call []].include?(call.name)

    method_call = call.receiver
    return unless method_call.is_a?(Prism::CallNode) && %i[method public_method singleton_method].include?(method_call.name)

    method_name = method_call.arguments&.arguments&.first
    return unless method_name.is_a?(Prism::SymbolNode) || method_name.is_a?(Prism::StringNode)
    return unless LOADER_METHODS.include?(method_name.unescaped)
    return unless method_object_loader_receiver?(method_call, method_name.unescaped)

    method_name.unescaped
  end

  def method_object_loader_receiver?(method_call, method_name)
    return kernel?(method_call.receiver) if method_call.name == :singleton_method
    return true if method_name == "autoload"
    return kernel?(method_call.receiver) if method_call.name == :public_method

    method_call.receiver.nil? || self_receiver?(method_call.receiver) || kernel?(method_call.receiver) || top_level_object_receiver?(method_call.receiver)
  end

  # Literals nested in a loader argument still contribute to the path the
  # loader receives: `require File.join(__dir__, "collavre_slack/engine")` is
  # a real dependency. The walk starts at each argument, not at the entire
  # statement, so a neighbouring `warn("collavre_slack")` remains prose.
  #
  # The static parts of an interpolated string count: the engine name in
  # "#{root}/collavre_slack/foo" is still a literal reference to it.
  def string_arguments(call)
    loader_arguments(call).flat_map do |argument|
      static_concatenation = static_string_concatenation(argument)
      static_concatenation.nil? ? string_literals_in(argument) : [ static_concatenation ]
    end
  end

  def loader_arguments(call)
    arguments = call.arguments&.arguments.to_a
    reflected_loader_method(call) ? arguments.drop(1) : arguments
  end

  def static_string_concatenation(node)
    return node.unescaped if node.is_a?(Prism::StringNode)
    if node.is_a?(Prism::EmbeddedStatementsNode)
      expressions = node.statements.body
      return unless expressions.one?

      return static_string_concatenation(expressions.first)
    end
    if node.is_a?(Prism::InterpolatedStringNode)
      parts = node.parts.map { |part| static_string_concatenation(part) }
      return parts.join if parts.all?
    end
    return unless node.is_a?(Prism::CallNode) && node.name == :+

    arguments = node.arguments&.arguments
    return unless arguments&.one?

    left = static_string_concatenation(node.receiver)
    right = static_string_concatenation(arguments.first)
    left + right if left && right
  end

  def static_symbol_concatenation(node)
    return node.unescaped if node.is_a?(Prism::SymbolNode)
    if node.is_a?(Prism::EmbeddedStatementsNode)
      expressions = node.statements.body
      return unless expressions.one?

      return static_symbol_part(expressions.first)
    end
    return unless node.is_a?(Prism::InterpolatedSymbolNode)

    parts = node.parts.map { |part| static_symbol_part(part) }
    parts.join if parts.all?
  end

  def static_symbol_part(node)
    static_symbol_concatenation(node) || static_string_concatenation(node)
  end

  def string_literals_in(node)
    case node
    when Prism::StringNode then [ node.unescaped ]
    when Prism::InterpolatedStringNode then node.parts.flat_map { |part| string_literals_in(part) }
    when Prism::Node then node.compact_child_nodes.flat_map { |child| string_literals_in(child) }
    else []
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
    return true if self_receiver?(call.receiver)
    return true if loader_method(call) == "autoload"
    return true if method_object_loader_method(call)
    return true if object_reflective_kernel_loader?(call)

    kernel?(call.receiver)
  end

  def object_reflective_kernel_loader?(call)
    %i[send __send__].include?(call.name) && reflected_loader_method(call) &&
      (top_level_object_receiver?(call.receiver) || ordinary_object_instance?(call.receiver))
  end

  def ordinary_object_instance?(node)
    node.is_a?(Prism::CallNode) && %i[new allocate].include?(node.name) &&
      (node.arguments.nil? || node.arguments.arguments.empty?) && top_level_object_receiver?(node.receiver)
  end

  def self_receiver?(node)
    node.is_a?(Prism::SelfNode)
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

  def top_level_object_receiver?(node)
    case node
    when Prism::ConstantReadNode then node.name == :Object
    when Prism::ConstantPathNode then node.name == :Object && top_level_path?(node.parent)
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
  # Ruby allows an explicit `.rb` suffix too, so remove it before comparing the
  # final feature segment with the reserved satellite prefix. This covers
  # published satellites that are not checked out in this monorepo too.
  def satellite_for(feature)
    return nil if feature.nil?

    Pathname.new(feature.delete_suffix(".rb")).cleanpath.each_filename.find { |segment| segment.match?(SATELLITE_GEM_NAME) }
  end

  def satellite_gem_dependencies(dependencies)
    dependencies.grep(SATELLITE_GEM_NAME)
  end

  # Gem::Specification.load evaluates the gemspec in the current environment.
  # A conditional dependency may therefore be absent in CI but present when the
  # core gem is built elsewhere. Read literal declarations from the syntax tree
  # as well, while retaining the evaluated specification for dynamic entries.
  def gemspec_dependency_names_in(source)
    gemspec_dependency_calls(Prism.parse(source).value).filter_map { |call| gemspec_dependency_name(call) }
  end

  def gemspec_dependency_name(call)
    static_string_concatenation(call.arguments&.arguments&.first)
  end

  def gemspec_dependency_calls(node, found = [], gemspec_receivers: [], specification_block: false)
    return found unless node.is_a?(Prism::Node)

    gemspec_receivers -= block_parameter_names(node) if node.is_a?(Prism::BlockNode) && !specification_block
    found << node if gemspec_dependency_call?(node, gemspec_receivers)
    node.compact_child_nodes.each do |child|
      nested_specification_block = gemspec_specification_block?(node, child)
      receivers = nested_specification_block ? gemspec_block_receivers(child) : gemspec_receivers
      gemspec_dependency_calls(child, found, gemspec_receivers: receivers, specification_block: nested_specification_block)
    end
    found
  end

  def gemspec_dependency_call?(node, gemspec_receivers)
    return false unless node.is_a?(Prism::CallNode)
    return false unless %i[add_dependency add_runtime_dependency].include?(node.name)

    node.receiver.nil? || gemspec_spec_receiver?(node.receiver, gemspec_receivers)
  end

  def gemspec_specification_block?(node, child)
    node.is_a?(Prism::CallNode) && node.name == :new && node.block.equal?(child) &&
      node.receiver&.slice&.delete_prefix("::") == "Gem::Specification"
  end

  # Gem::Specification yields the specification as its first block argument.
  # Track its declared name so static checks are independent of local spelling.
  def gemspec_block_receivers(block)
    parameters = block.parameters&.parameters
    parameter = parameters&.requireds&.first || parameters&.optionals&.first
    parameter ? [ parameter.name ] : []
  end

  def block_parameter_names(block)
    block.locals
  end

  def gemspec_spec_receiver?(receiver, gemspec_receivers)
    return gemspec_receivers.include?(receiver.name) if receiver.is_a?(Prism::LocalVariableReadNode)

    receiver.is_a?(Prism::CallNode) && receiver.receiver.nil? && receiver.name == :spec &&
      receiver.arguments.nil?
  end

  def satellite_constant?(name)
    name.match?(SATELLITE_CONSTANT)
  end

  # Network URLs are fetched externally rather than resolved through Propshaft.
  # Local `file:` URLs still name files, so keep them in the boundary scanner.
  def remote_asset_url?(path)
    path.match?(%r{\A(?:https?:|//)}i)
  end

  def tokens(source)
    Prism.lex(source).value.map(&:first)
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end
end
