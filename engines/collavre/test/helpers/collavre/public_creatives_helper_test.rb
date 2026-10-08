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

    test "root bodies retain composite blocks and unwrapped links" do
      [
        '<blockquote><p>Quoted text</p></blockquote>',
        '<ul><li>First item</li><li>Second item</li></ul>',
        '<p><a href="/guide">Guide</a></p>',
        '<a href="/manual" download="manual">Manual</a>'
      ].each do |html|
        assert_equal html, public_creative_body(creative_with(html))
        assert_not public_creative_heading?(creative_with(html))
      end
    end

    test "root bodies preserve rich fragments without title blocks and long plain text" do
      html = '<div>Overview</div><video src="/movie.mp4"></video>'
      assert_equal html, public_creative_body(creative_with(html))
      assert_not public_creative_heading?(creative_with(html))
      text = 'Long published content ' * 20
      assert_equal text, public_creative_body(creative_with(text))
      assert_not public_creative_heading?(creative_with(text))
    end

    test "root bodies retain simple blocks whose title is truncated" do
      text = "Published paragraph " * 20
      %w[p h1 h2 h3 h4 h5 h6].each do |tag|
        html = "<#{tag}>#{text}</#{tag}>"
        creative = creative_with(html)
        assert_equal Creative::TITLE_MAX_LENGTH, creative.public_title.length
        assert_equal html, public_creative_body(creative)
      end
    end

    test "root bodies remove only complete simple titles" do
      text = "x" * Creative::TITLE_MAX_LENGTH
      assert_equal "<p>Body</p>", public_creative_body(creative_with("<p>#{text}</p><p>Body</p>"))
      html = "<p>#{text}x</p><p>Body</p>"
      assert_equal html, public_creative_body(creative_with(html))
    end

    test "heading tags start at h2 and stop at h6" do
      assert_equal "h2", public_creative_heading_tag(1)
      assert_equal "h4", public_creative_heading_tag(3)
      assert_equal "h6", public_creative_heading_tag(9)
    end
  end
end
