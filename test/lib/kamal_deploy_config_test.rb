require "test_helper"
require "erb"
require "yaml"

class KamalDeployConfigTest < ActiveSupport::TestCase
  ENVIRONMENT_VARIABLES = %w[AI_AGENT_THREADS DB_POOL SOLID_QUEUE_IN_PUMA].freeze

  setup do
    @original_environment = ENVIRONMENT_VARIABLES.to_h { |key| [ key, ENV[key] ] }
  end

  teardown do
    @original_environment.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "renders default clear environment values as strings" do
    ENVIRONMENT_VARIABLES.each { |key| ENV.delete(key) }

    clear_environment = rendered_clear_environment

    assert_equal "12", clear_environment["AI_AGENT_THREADS"]
    assert_equal "true", clear_environment["SOLID_QUEUE_IN_PUMA"]
    assert_not clear_environment.key?("DB_POOL")
  end

  test "renders numeric and boolean-looking overrides as strings" do
    ENV["AI_AGENT_THREADS"] = "24"
    ENV["DB_POOL"] = "48"
    ENV["SOLID_QUEUE_IN_PUMA"] = "false"

    clear_environment = rendered_clear_environment

    assert_equal "24", clear_environment["AI_AGENT_THREADS"]
    assert_equal "48", clear_environment["DB_POOL"]
    assert_equal "false", clear_environment["SOLID_QUEUE_IN_PUMA"]
  end

  private
    def rendered_clear_environment
      template = ERB.new(Rails.root.join("config/deploy.yml").read).result
      YAML.safe_load(template).dig("env", "clear")
    end
end
