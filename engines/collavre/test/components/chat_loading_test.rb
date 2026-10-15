require "test_helper"

class ChatLoadingTest < ActionView::TestCase
  test "renders decorative emoji loading dots with a localized status" do
    %i[en ko].each do |locale|
      I18n.with_locale(locale) do
        render partial: "collavre/comments/loading"
        assert_select ".comments-loading[role='status'][aria-label=?]", I18n.t("app.loading")
        assert_select ".comments-loading[data-controller='comments--loading']"
        assert_select ".creative-loading-indicator[aria-hidden='true'] .creative-loading-dot", count: 3
      end
    end
  end
end
