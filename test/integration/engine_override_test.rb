require "test_helper"
require "fileutils"
require_relative "../../lib/local_engine_setup"

class EngineOverrideTest < ActionDispatch::IntegrationTest
  TEMP_ENGINE_PATH = Rails.root.join("engines/test_override_engine")

  setup do
    # 1. Create a temporary engine structure
    FileUtils.mkdir_p(TEMP_ENGINE_PATH.join("config/locales"))
    FileUtils.mkdir_p(TEMP_ENGINE_PATH.join("app/views/shared"))

    # 2. Define an I18n override for 'app.name'
    File.write(TEMP_ENGINE_PATH.join("config/locales/en.yml"), <<~YAML)
      en:
        app:
          name: "Overridden App Name"
    YAML

    # 3. Define a View Partial override for the footer
    File.write(TEMP_ENGINE_PATH.join("app/views/shared/_footer.html.erb"), <<~ERB)
      <div id="custom-footer">
        Custom Enterprise Footer
      </div>
    ERB

    # 4. Define the Engine Class dynamically so LocalEngineSetup finds it
    unless defined?(TestOverrideEngine::Engine)
      module TestOverrideEngine
        class Engine < ::Rails::Engine
          # Force root to be our temp path
          def self.root
            Pathname.new(TEMP_ENGINE_PATH)
          end
        end
      end
    end

    # 5. Trigger the Engine Setup logic
    LocalEngineSetup.run(Rails.application)

    # 6. Manually sync I18n.load_path to config (simulating Rails boot behavior for test)
    # Since LocalEngineSetup updates app.config, but at runtime I18n.load_path is separate
    I18n.load_path = Rails.application.config.i18n.load_path

    # Reload I18n backend
    I18n.backend.reload!
  end

  teardown do
    # Cleanup files
    FileUtils.rm_rf(TEMP_ENGINE_PATH)

    # Reset I18n
    I18n.backend.reload!
  end

  test "overrides app name translation" do
    assert_equal "Overridden App Name", I18n.t("app.name")
  end

  test "overrides footer partial in layout" do
    get root_path

    assert_response :success
    assert_select "#custom-footer", text: "Custom Enterprise Footer"
    assert_no_match "GitHub", response.body
  end
end
