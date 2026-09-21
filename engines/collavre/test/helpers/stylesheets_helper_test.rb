require "test_helper"

class Collavre::StylesheetsHelperTest < ActionView::TestCase
  test "engine exposes the helper to every view context" do
    assert_includes ActionView::Base.ancestors, Collavre::StylesheetsHelper
  end

  test "host view context responds without including Collavre::ApplicationHelper" do
    lookup_context = ActionView::LookupContext.new([])
    host_view = ActionView::Base.with_empty_template_cache.new(lookup_context, {}, nil)

    assert_not_includes host_view.class.ancestors, Collavre::ApplicationHelper
    assert_respond_to host_view, :collavre_stylesheets
  end

  test "collavre_stylesheets renders every engine stylesheet" do
    html = collavre_stylesheets

    Collavre::StylesheetsHelper::COLLAVRE_STYLESHEETS.each do |sheet|
      assert_includes html, sheet
    end
  end

  test "host layout includes gateway styles without a head content slot" do
    lookup_context = ActionView::LookupContext.new([])
    host_view = ActionView::Base.with_empty_template_cache.new(lookup_context, {}, nil)

    html = host_view.render(inline: "<head><%= collavre_stylesheets %></head>")
    links = Nokogiri::HTML(html).css('head link[href*="collavre/agent_gateways"]')

    assert_equal 1, links.size
    assert_equal "stylesheet", links.first["rel"]
  end

  test "collavre_stylesheets renders print stylesheets with print media" do
    html = collavre_stylesheets

    Collavre::StylesheetsHelper::COLLAVRE_PRINT_STYLESHEETS.each do |sheet|
      assert_match(/#{Regexp.escape(sheet)}[^>]*media="print"/, html)
    end
  end

  test "Collavre::ApplicationHelper keeps the stylesheet helper" do
    assert_includes Collavre::ApplicationHelper.ancestors, Collavre::StylesheetsHelper
  end
end
