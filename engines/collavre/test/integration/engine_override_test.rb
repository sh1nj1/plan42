require "test_helper"
require "fileutils"
require "local_engine_setup"
require "minitest/mock"
require "ostruct"
require "securerandom"

class EngineOverrideTest < ActionDispatch::IntegrationTest
  # Disable parallelization for this test class because it mutates global state
  # (ActionController::Base.view_paths, I18n.load_path) which can affect other tests.
  parallelize(workers: 1)

  setup do
    # Capture global state to restore later
    @original_i18n_load_path = I18n.load_path.dup
    @original_config_i18n_load_path = Rails.application.config.i18n.load_path.dup
    @original_view_paths = ActionController::Base.view_paths.dup

    # Reset LocalEngineSetup state
    LocalEngineSetup.reset!

    # Setup unique paths for this test run to avoid collision in parallel tests
    @temp_root = Rails.root.join("tmp/test_engines/#{SecureRandom.hex(8)}")
    @temp_engine_path = @temp_root.join("test_override_engine")

    # 1. Create a temporary engine structure in ISOLATION
    FileUtils.mkdir_p(@temp_engine_path.join("config/locales"))
    FileUtils.mkdir_p(@temp_engine_path.join("app/views/shared"))
    FileUtils.mkdir_p(@temp_engine_path.join("public")) # For static asset test

    # 2. Define an I18n override for 'app.name'
    File.write(@temp_engine_path.join("config/locales/en.yml"), <<~YAML)
      en:
        app:
          name: "Overridden App Name"
    YAML

    # 3. Define a View Partial override for the footer
    File.write(@temp_engine_path.join("app/views/shared/_footer.html.erb"), <<~ERB)
      <div id="custom-footer">
        Custom Enterprise Footer
      </div>
    ERB

    # 4. Define the Engine Class dynamically so LocalEngineSetup finds it
    unless defined?(TestOverrideEngine::Engine)
      module TestOverrideEngine
        class Engine < ::Rails::Engine
          # Value holder for dynamic root
          cattr_accessor :dynamic_root

          def self.root
            # If dynamic_root is set, use it. Otherwise fallback (though shouldn't happen in test)
            dynamic_root || super
          end
        end
      end
    end

    # Update the engine root for this test run
    TestOverrideEngine::Engine.dynamic_root = Pathname.new(@temp_engine_path)

    # SIMULATE RAILS BEHAVIOR:
    # Rails automatically appends engine view paths during initialization.
    # We strip this in teardown, but we must add it here to test that LocalEngineSetup
    # correctly MOVES it to the front (prepends) even if it exists.
    ActionController::Base.append_view_path(@temp_engine_path.join("app/views").to_s)

    # 5. Trigger the Engine Setup logic with our CUSTOM ROOT
    LocalEngineSetup.run(Rails.application, root: @temp_root)

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
    FileUtils.rm_rf(@temp_root)

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
    assert_select "footer", text: /GitHub/, count: 0
  end

  test "idempotency: running setup twice does not duplicate view paths" do
    initial_count = ActionController::Base.view_paths.count

    # Run again against Rails.application
    LocalEngineSetup.run(Rails.application, root: @temp_root)

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
       def include?(*args); false; end # Fallback
     end

     middleware_recorder = mock_middleware_class.new

     # Mock App Structure
     app_struct = OpenStruct.new(
       config: OpenStruct.new(
         public_file_server: OpenStruct.new(
           enabled: true,
           index_name: "index",
           headers: { "Cache-Control" => "public, max-age=3600" }
         ),
         middleware: middleware_recorder,
         paths: Hash.new { |h, k| h[k] = [] },
         i18n: OpenStruct.new(load_path: [])
       ),
       middleware: [] # Live string middleware list (empty for mock)
     )

     # Reset LocalEngineSetup so it processes this "new" app run
     LocalEngineSetup.reset!

     # Run Setup against Mock
     LocalEngineSetup.run(app_struct, root: @temp_root)

     # Verify middleware was inserted
     engine_public = @temp_engine_path.join("public").to_s

     assert_equal 1, middleware_recorder.calls.length, "Should have inserted static middleware once"

     # Check arguments passed to insert_before:
     # [TargetClass, MiddlewareClass, Path, {index:, headers:}]
     args = middleware_recorder.calls.first
     assert_equal engine_public, args[2], "Should insert the correct public path"
     assert_equal "index", args[3][:index], "Should pass index config"
     assert_equal({ "Cache-Control" => "public, max-age=3600" }, args[3][:headers], "Should pass headers config")
  end
end
