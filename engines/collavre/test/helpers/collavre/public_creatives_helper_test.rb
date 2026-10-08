require "test_helper"

module Collavre
  class PublicCreativesHelperTest < ActionView::TestCase
    include Collavre::PublicCreativesHelper

    def creative_with(html)
      Creative.new(description: html)
    end

    test "a short single line is a heading" do
      assert public_creative_heading?(creative_with("<p>Goals for <strong>Q4</strong></p>"))
      assert public_creative_heading?(creative_with("Plain title"))
    end

    test "rich or long content is body" do
      assert_not public_creative_heading?(creative_with("<p>One</p><p>Two</p>"))
      assert_not public_creative_heading?(creative_with("<ul><li>Item</li></ul>"))
      assert_not public_creative_heading?(creative_with("<p>#{'word ' * 30}</p>"))
      assert_not public_creative_heading?(creative_with(""))
    end

    test "heading tags start at h2 and stop at h6" do
      assert_equal "h2", public_creative_heading_tag(1)
      assert_equal "h4", public_creative_heading_tag(3)
      assert_equal "h6", public_creative_heading_tag(9)
    end
  end
end
