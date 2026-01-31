require_relative "../test_helper"

class NotionCreativeExporterTest < ActiveSupport::TestCase
  def setup
    @user = create_user(email: "exporter-test@example.com", name: "Exporter Test User")

    @creative = Collavre::Creative.create!(
      user: @user,
      description: "Test Creative Title",
      progress: 0.0
    )

    @exporter = CollavreNotion::NotionCreativeExporter.new(@creative)
  end

  test "should export creative as heading block" do
    blocks = @exporter.export_blocks

    assert blocks.is_a?(Array), "Should return an array"
    assert blocks.length >= 1, "Should export at least one block"

    block = blocks.first
    assert block.present?, "First block should not be nil"
    assert block.is_a?(Hash), "Block should be a hash"

    assert_equal "block", block[:object]
    assert_equal "heading_1", block[:type]

    # Check the structure more carefully
    assert block.key?(:heading_1), "Block should have heading_1 key: #{block.keys}"
    heading_data = block[:heading_1]
    assert heading_data.present?, "Heading data should be present"
    assert heading_data.key?(:rich_text), "Should have rich_text: #{heading_data.keys}"

    rich_text = heading_data[:rich_text]
    assert rich_text.is_a?(Array), "Rich text should be array"
    assert rich_text.length > 0, "Rich text should have content"

    text_block = rich_text.first
    assert text_block.key?(:text), "Should have text key"
    assert_equal "Test Creative Title", text_block[:text][:content]
  end

  test "should export with progress when enabled" do
    @creative.update!(progress: 0.75)
    exporter = CollavreNotion::NotionCreativeExporter.new(@creative, with_progress: true)

    blocks = exporter.export_blocks
    block = blocks.first

    assert_includes block[:heading_1][:rich_text][0][:text][:content], "(75%)"
  end

  test "should handle deeper level creatives as bulleted lists" do
    creative = Collavre::Creative.create!(
      user: @user,
      description: "Deep Level Creative",
      progress: 0.0
    )

    # Test with level 5 (should use bulleted list)
    exporter = CollavreNotion::NotionCreativeExporter.new(creative)
    blocks = exporter.send(:convert_creative_to_blocks, creative, level: 5)

    assert_equal "bulleted_list_item", blocks.first[:type]
  end

  test "should export tree of creatives" do
    parent = Collavre::Creative.create!(
      user: @user,
      description: "Parent Creative",
      progress: 0.0
    )

    Collavre::Creative.create!(
      user: @user,
      description: "Child 1",
      parent: parent,
      progress: 0.0
    )

    Collavre::Creative.create!(
      user: @user,
      description: "Child 2",
      parent: parent,
      progress: 0.0
    )

    exporter = CollavreNotion::NotionCreativeExporter.new(parent)
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
    creative = Collavre::Creative.create!(
      user: @user,
      description: "<div class='trix-content'><div>Clean Title</div></div>",
      progress: 0.0
    )

    exporter = CollavreNotion::NotionCreativeExporter.new(creative)
    blocks = exporter.export_blocks

    assert_equal "Clean Title", blocks.first[:heading_1][:rich_text][0][:text][:content]
  end

  test "should extract text content from HTML" do
    html = "<p><strong>Bold</strong> and <em>italic</em> text</p>"
    text = @exporter.send(:extract_text_content, html)

    assert_equal "Bold and italic text", text
  end

  test "should handle empty or nil content" do
    creative = Collavre::Creative.create!(
      user: @user,
      description: "Placeholder",
      progress: 0.0
    )

    creative.stub(:effective_description, nil) do
      exporter = CollavreNotion::NotionCreativeExporter.new(creative)
      blocks = exporter.export_blocks
      assert_kind_of Array, blocks
    end

    creative.stub(:effective_description, ActionText::Content.new("")) do
      exporter = CollavreNotion::NotionCreativeExporter.new(creative)
      blocks = exporter.export_blocks
      assert_kind_of Array, blocks
    end
  end
end
