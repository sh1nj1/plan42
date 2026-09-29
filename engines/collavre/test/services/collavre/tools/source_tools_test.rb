# frozen_string_literal: true

require "test_helper"

class Collavre::Tools::SourceToolsTest < ActiveSupport::TestCase
  setup do
    @kollavy = Collavre::User.create!(email: Collavre::Kollavy::EMAIL, name: "Kollavy", password: "password-123",
                                      llm_vendor: "google", llm_model: "gemini-2.5-flash")
    @other = users(:one)
  end

  test "tools declare Kollavy as their only user" do
    [ Collavre::Tools::SourceListService, Collavre::Tools::SourceSearchService, Collavre::Tools::SourceReadService ].each do |tool|
      assert_equal [ Collavre::Kollavy::EMAIL ], tool.allowed_user_emails
    end
  end

  test "Kollavy can list, search and read the running source" do
    Collavre::Current.set(user: @kollavy) do
      roots = Collavre::Tools::SourceListService.new.call[:entries].map { |e| e[:path] }
      assert_includes roots, "engines/collavre/app"

      found = Collavre::Tools::SourceSearchService.new.call(query: "MAIN_TOPIC_NAME =", path: "engines/collavre/app/models")
      assert_equal "engines/collavre/app/models/collavre/creative.rb", found[:matches].first[:path]

      read = Collavre::Tools::SourceReadService.new.call(path: "config/routes.rb", start_line: 1, end_line: 1)
      assert_equal 1, read[:end_line]
      assert_equal read, Collavre::Tools::SourceReadService.new.call(path: "config/routes.rb", end_line: 1)
    end
  end

  test "access errors come back as tool errors" do
    Collavre::Current.set(user: @kollavy) do
      assert_match "Not found or not readable", Collavre::Tools::SourceReadService.new.call(path: "config/master.key")[:error]
      assert_match "query is required", Collavre::Tools::SourceSearchService.new.call(query: "")[:error]
    end
  end

  test "any other caller is refused" do
    unavailable = I18n.t("collavre.mcp_tools.unavailable")
    [ @other, nil ].each do |user|
      Collavre::Current.set(user: user) do
        assert_equal unavailable, Collavre::Tools::SourceListService.new.call[:error]
        assert_equal unavailable, Collavre::Tools::SourceSearchService.new.call(query: "x")[:error]
        assert_equal unavailable, Collavre::Tools::SourceReadService.new.call(path: "config/routes.rb")[:error]
      end
    end
  end
end
