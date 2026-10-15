require "test_helper"

class ChatLoadingTest < ActionView::TestCase
  test "renders three decorative skeleton rows with a localized status" do
    %i[en ko].each do |locale|
      I18n.with_locale(locale) do
        render partial: "collavre/comments/loading"
        assert_select ".comments-loading[role='status'][aria-label=?]", I18n.t("app.loading")
        assert_select ".comments-loading-row[aria-hidden='true']", count: 3
      end
    end
  end
end
