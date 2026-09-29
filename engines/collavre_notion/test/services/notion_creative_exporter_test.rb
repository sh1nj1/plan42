require_relative "../test_helper"

class NotionCreativeExporterTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    @creative = create_creative(@user)
  end

  test "exports own text without descendant content" do
    Collavre::Creative.create!(user: @user, parent: @creative, description: "Child page")
    blocks = export
    assert_equal [ "paragraph" ], blocks.pluck(:type)
    assert_equal "Notion test creative", text(blocks.first)
  end

  test "cleans HTML comments and entities" do
    @creative.update!(description: "<p>Clean &amp; decoded<!-- hidden --></p>")
    assert_equal "Clean & decoded", text(export.first)
  end

  test "nil and empty descriptions have no body blocks" do
    [ nil, "", ActionText::Content.new("") ].each do |value|
      @creative.stub(:effective_description, value) { assert_empty export }
    end
  end

  test "splits long text without truncating whitespace at chunk boundaries" do
    value = "가" * 1999 + "  " + "나" * 2000
    @creative.stub(:effective_description, value) do
      blocks = export
      assert_equal value, blocks.map { |block| text(block) }.join
      assert blocks.all? { |block| text(block).length <= 2000 }
    end
  end

  test "optional progress is an own-page paragraph" do
    @creative.update!(progress: 0.75)
    assert_equal "(75%)", text(CollavreNotion::NotionCreativeExporter.new(@creative, with_progress: true).export_blocks.last)
  end

  test "HTML tables retain surrounding text and long cells" do
    html = "<p>Before</p><table><tr><th>Title</th><th>Other</th></tr><tr><td>#{'x' * 4001}</td></tr></table><p>After</p>"
    @creative.stub(:effective_description, html) do
      blocks = export
      assert_equal [ "paragraph", "table", "paragraph" ], blocks.pluck(:type)
      assert_equal "Before", text(blocks.first)
      assert_equal "After", text(blocks.last)
      table = blocks[1][:table]
      assert_equal 2, table[:table_width]
      cells = table[:children].last[:table_row][:cells]
      assert_equal "x" * 4001, cells.first.map { |chunk| chunk[:text][:content] }.join
      assert_equal [], cells.last
    end
  end

  test "splits large tables into API sized blocks" do
    html = "<table>#{'<tr><td>row</td></tr>' * 201}</table>"
    @creative.stub(:effective_description, html) do
      assert_equal [ 100, 100, 1 ], export.map { |block| block[:table][:children].size }
    end
  end

  test "exports markdown tables" do
    @creative.stub(:effective_description, "| Name | Value |\n| --- | --- |\n| Test | 42 |") do
      table = export.first[:table]
      assert_equal 2, table[:table_width]
      assert_equal 2, table[:children].size
    end
  end

  test "image placeholders use the locale" do
    @creative.stub(:effective_description, '<img src="data:image/png;base64,abc" alt="">') do
      I18n.with_locale(:ko) { assert_equal "📷 이미지", text(export.last) }
    end
  end

  test "attachment placeholders resolve signed attachments and localize fallback captions" do
    @creative.stub(:effective_description, '<action-text-attachment sgid="signed"></action-text-attachment>') do
      GlobalID::Locator.stub(:locate_signed, Object.new) do
        I18n.with_locale(:ko) { assert_equal "📷 이미지 첨부파일", text(export.last) }
      end
      GlobalID::Locator.stub(:locate_signed, nil) { assert_empty export }
    end
  end

  test "paragraph boundaries and line breaks are preserved" do
    @creative.stub(:effective_description, "<p>First<br>line</p><p>Second</p>") do
      assert_equal "First\nline\nSecond", text(export.first)
    end
  end

  private

  def export
    CollavreNotion::NotionCreativeExporter.new(@creative).export_blocks
  end

  def text(block)
    block[:paragraph][:rich_text].map { |part| part[:text][:content] }.join
  end
end
