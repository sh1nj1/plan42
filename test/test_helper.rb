ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Add engines test directories to the test runner
# Note: We do not auto-load engine tests here to avoid running them during targeted app tests.
# Use `rails test engines/` or `rake test:engines` to run engine tests.

# Load H2 test database schema
# The H2 database is external in production but uses SQLite for testing
h2_schema_file = Rails.root.join("db", "h2_test_schema.rb")
if File.exist?(h2_schema_file)
  # Ensure H2 database directory exists
  h2_db_path = Rails.root.join("storage", "test-h2.sqlite3")
  FileUtils.mkdir_p(File.dirname(h2_db_path))

  # Load the schema module
  require h2_schema_file

  # Load schema into H2 database connection
  ActiveRecord::Migration.verbose = false
  H2TestSchema.load!(Mis2::H2Record.connection)
end

# Load H3 test database schema
h3_schema_file = Rails.root.join("db", "h3_test_schema.rb")
if File.exist?(h3_schema_file)
  h3_db_path = Rails.root.join("storage", "test-h3.sqlite3")
  FileUtils.mkdir_p(File.dirname(h3_db_path))

  require h3_schema_file

  ActiveRecord::Migration.verbose = false
  H3TestSchema.load!(Mis2::H3Record.connection)
end

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    setup do
      Rails.cache.clear
      Current.reset
      # Rebuild the closure tree for Creatives fixture
      Creative.rebuild! if defined?(Creative)
    end
  end
end

TEST_PASSWORD = "password123"

module IntegrationAuthHelper
  def sign_in_as(user, password: TEST_PASSWORD, follow_redirect: false)
    user.update!(email_verified_at: Time.current) unless user.email_verified?
    post session_path, params: { email: user.email, password: password }
    assert_response :redirect
    follow_redirect! if follow_redirect && response.redirect?
  end

  def sign_out
    delete session_path
  end
end

module H2TestHelper
  # Ensures H2 schema is loaded for parallel test workers
  # Each parallel worker may have its own database that needs the schema
  def ensure_h2_schema_loaded!
    h2_schema_file = Rails.root.join("db", "h2_test_schema.rb")
    return unless File.exist?(h2_schema_file)

    connection = Mis2::H2Record.connection
    unless connection.table_exists?("brain_organization")
      require h2_schema_file
      H2TestSchema.load!(connection)
    end
  end
end

module H3TestHelper
  def ensure_h3_schema_loaded!
    h3_schema_file = Rails.root.join("db", "h3_test_schema.rb")
    return unless File.exist?(h3_schema_file)

    connection = Mis2::H3Record.connection
    unless connection.table_exists?("organization")
      require h3_schema_file
      H3TestSchema.load!(connection)
    end
  end

  def create_h3_org_admin(org_attrs: {}, dept_attrs: {}, admin_attrs: {})
    org = Mis2::H3::Organization.create!({
      active_yn: false, deleted_yn: false,
      created_at: Time.current, created_by: "test"
    }.merge(org_attrs))

    dept = Mis2::H3::OrganizationDepartment.create!({
      organization_id: org.id,
      active_yn: true, deleted_yn: false,
      created_at: Time.current, created_by: "test"
    }.merge(dept_attrs))

    admin = Mis2::H3::OrganizationAdmin.create!({
      organization_department_id: dept.id,
      role: "ORGANIZATION_ADMIN",
      created_at: Time.current, created_by: "test"
    }.merge(admin_attrs))

    { org: org, dept: dept, admin: admin }
  end

  def cleanup_h3_test_data(*records_sets)
    records_sets.each do |records|
      begin
        Mis2::H3::OrganizationAdmin.where(id: records[:admin]&.id).delete_all
        Mis2::H3::OrganizationDepartment.where(id: records[:dept]&.id).delete_all
        Mis2::H3::Organization.where(id: records[:org]&.id).delete_all
      rescue ActiveRecord::StatementInvalid
        # Ignore if H3 tables don't exist (parallel test worker without schema)
      end
    end
    Mis2::ActivityLog.where(action: "h3_organization_approve").delete_all
  end
end

class ActionDispatch::IntegrationTest
  include IntegrationAuthHelper
  include H2TestHelper
  include H3TestHelper
  include Collavre::Engine.routes.url_helpers
end
