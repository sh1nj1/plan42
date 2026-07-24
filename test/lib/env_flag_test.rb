# frozen_string_literal: true

require "test_helper"

class EnvFlagTest < ActiveSupport::TestCase
  # `config/puma.rb` decides whether to run the Solid Queue supervisor from an
  # ENV flag. A bare `if ENV["FLAG"]` treats "false" and "" as enabled, so a
  # host meant to serve web traffic only still claims jobs from the shared
  # queue. These cases pin the affirmative-only reading.

  test "reads affirmative spellings as enabled" do
    %w[1 true t yes y on TRUE True YES On].each do |value|
      assert EnvFlag.enabled?("FLAG", env: { "FLAG" => value }),
             "expected #{value.inspect} to enable the flag"
    end
  end

  test "reads negative spellings as disabled" do
    %w[0 false f no n off FALSE Off].each do |value|
      assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => value }),
                 "expected #{value.inspect} to disable the flag"
    end
  end

  test "reads a blank value as disabled" do
    assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => "" })
    assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => "   " })
  end

  test "reads an unrecognized value as disabled" do
    assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => "maybe" })
  end

  test "ignores surrounding whitespace" do
    assert EnvFlag.enabled?("FLAG", env: { "FLAG" => " true\n" })
  end

  test "falls back to the default when the variable is unset" do
    assert_not EnvFlag.enabled?("FLAG", env: {})
    assert EnvFlag.enabled?("FLAG", env: {}, default: true)
  end

  test "an explicit value overrides the default" do
    assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => "false" }, default: true)
  end

  test "a blank value overrides the default" do
    # Deploy templates render an empty string for an unset variable; that must
    # not read as "unset" and pick up an enabled default.
    assert_not EnvFlag.enabled?("FLAG", env: { "FLAG" => "" }, default: true)
  end

  test "defaults to the process environment" do
    ENV["ENV_FLAG_TEST"] = "true"
    assert EnvFlag.enabled?("ENV_FLAG_TEST")
  ensure
    ENV.delete("ENV_FLAG_TEST")
  end
end
