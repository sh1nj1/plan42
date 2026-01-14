require "test_helper"
require "fileutils"
require_relative "../../lib/local_engine_setup"
require "minitest/mock"

class EngineOverrideTest < ActionDispatch::IntegrationTest
  # Use a path OUTSIDE the main 'engines' bucket to avoid polluting parallel tests
  TEMP_ROOT = Rails.root.join("tmp/test_engines")
  TEMP_ENGINE_PATH = TEMP_ROOT.join("test_override_engine")

  setup do
    # Capture global state to restore later
    @original_i18n_load_path = I18n.load_path.dup
    @original_config_i18n_load_path = Rails.application.config.i18n.load_path.dup
    @original_view_paths = ActionController::Base.view_paths.dup

    # Reset LocalEngineSetup state
    LocalEngineSetup.reset!

    # 1. Create a temporary engine structure in ISOLATION
    FileUtils.mkdir_p(TEMP_ENGINE_PATH.join("config/locales"))
    FileUtils.mkdir_p(TEMP_ENGINE_PATH.join("app/views/shared"))
    FileUtils.mkdir_p(TEMP_ENGINE_PATH.join("public")) # For static asset test

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

    # 5. Trigger the Engine Setup logic with our CUSTOM ROOT
    LocalEngineSetup.run(Rails.application, root: TEMP_ROOT)

    # 6. Manually sync I18n.load_path to config (simulating Rails boot behavior for test)
    I18n.load_path = Rails.application.config.i18n.load_path

    # Reload I18n backend
    I18n.backend.reload!
  end

  teardown do
    # Restore global state
    I18n.load_path = @original_i18n_load_path
    Rails.application.config.i18n.load_path = @original_config_i18n_load_path
    ActionController::Base.view_paths = @original_view_paths

    # Reset LocalEngineSetup state
    LocalEngineSetup.reset!

    # Cleanup files
    FileUtils.rm_rf(TEMP_ENGINE_PATH)

    # Reload I18n backend to flush the bad paths
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

  test "idempotency: running setup twice does not duplicate view paths" do
    initial_count = ActionController::Base.view_paths.count

    # Run again against Rails.application
    LocalEngineSetup.run(Rails.application, root: TEMP_ROOT)

    assert_equal initial_count, ActionController::Base.view_paths.count
  end

  test "static assets: validates middleware insertion only when enabled" do
     # We use a Mock App because Rails.application.config.middleware is frozen at runtime
     # and we want to verify the logic of LocalEngineSetup

     # Creating a minimal class for middleware recorder to mock config.middleware
     mock_middleware_class = Class.new do
       attr_reader :calls
       def initialize; @calls = []; end
       def operations; []; end
       def insert_before(*args); @calls << args; end
       def frozen?; false; end # Important for our new check
     end

     middleware_recorder = mock_middleware_class.new

     # Mock App Structure
     app_struct = OpenStruct.new(
       config: OpenStruct.new(
         public_file_server: OpenStruct.new(enabled: true), # SIMULATE ENABLED
         middleware: middleware_recorder,
         paths: Hash.new { |h, k| h[k] = [] },
         i18n: OpenStruct.new(load_path: [])
       ),
       middleware: [] # Live string middleware list (empty for mock)
     )

     # Reset LocalEngineSetup so it processes this "new" app run
     LocalEngineSetup.reset!

     # Run Setup against Mock
     LocalEngineSetup.run(app_struct, root: TEMP_ROOT)

     # Verify middleware was inserted
     engine_public = TEMP_ENGINE_PATH.join("public").to_s

     assert_equal 1, middleware_recorder.calls.length, "Should have inserted static middleware once"
     # args are [ActionDispatch::Static, ActionDispatch::Static, public_path]
     assert_equal engine_public, middleware_recorder.calls.first.last, "Should insert the correct public path"
  end
end
