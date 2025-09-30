require "test_helper"

class NotionCreativeExporterTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123",
      name: "Test User"
    )

    @creative = Creative.create!(
      user: @user,
      description: "Test Creative Title"
    )

    @exporter = NotionCreativeExporter.new(@creative)
  end

  test "should export creative as heading block" do
    blocks = @exporter.export_blocks

    assert_equal 1, blocks.length
    block = blocks.first

    assert_equal "block", block[:object]
    assert_equal "heading_1", block[:type]
    assert_equal "Test Creative Title", block[:heading_1][:rich_text][0][:text][:content]
  end

  test "should export with progress when enabled" do
    @creative.update!(progress: 0.75)
    exporter = NotionCreativeExporter.new(@creative, with_progress: true)

    blocks = exporter.export_blocks
    block = blocks.first

    assert_includes block[:heading_1][:rich_text][0][:text][:content], "(75%)"
  end

  test "should handle deeper level creatives as bulleted lists" do
    creative = Creative.create!(
      user: @user,
      description: "Deep Level Creative"
    )

    # Test with level 5 (should use bulleted list)
    exporter = NotionCreativeExporter.new(creative)
    blocks = exporter.send(:convert_creative_to_blocks, creative, level: 5)

    assert_equal "bulleted_list_item", blocks.first[:type]
  end

  test "should export tree of creatives" do
    parent = Creative.create!(
      user: @user,
      description: "Parent Creative"
    )

    child1 = Creative.create!(
      user: @user,
      description: "Child 1",
      parent: parent
    )

    child2 = Creative.create!(
      user: @user,
      description: "Child 2",
      parent: parent
    )

    exporter = NotionCreativeExporter.new(parent)
    blocks = exporter.export_tree_blocks([ parent ])

    # Should have blocks for parent and both children
    assert_operator blocks.length, :>=, 3

    # First block should be parent
    assert_equal "Parent Creative", blocks.first[:heading_1][:rich_text][0][:text][:content]
  end

  test "should create rich text with proper formatting" do
    rich_text = @exporter.send(:create_rich_text, "Test Text")

    expected = {
      type: "text",
      text: { content: "Test Text" },
      annotations: {
        bold: false,
        italic: false,
        strikethrough: false,
        underline: false,
        code: false,
        color: "default"
      }
    }

    assert_equal expected, rich_text
  end

  test "should handle HTML content cleaning" do
    creative = Creative.create!(
      user: @user,
      description: "<div class='trix-content'><div>Clean Title</div></div>"
    )

    exporter = NotionCreativeExporter.new(creative)
    blocks = exporter.export_blocks

    assert_equal "Clean Title", blocks.first[:heading_1][:rich_text][0][:text][:content]
  end

  test "should extract text content from HTML" do
    html = "<p><strong>Bold</strong> and <em>italic</em> text</p>"
    text = @exporter.send(:extract_text_content, html)

    assert_equal "Bold and italic text", text
  end

  test "should handle empty or nil content" do
    creative = Creative.create!(
      user: @user,
      description: ""
    )

    exporter = NotionCreativeExporter.new(creative)
    blocks = exporter.export_blocks

    # Should handle empty content gracefully
    assert blocks.is_a?(Array)
  end
end
