require "test_helper"

class MarkdownImporterTest < ActiveSupport::TestCase
  test "skips horizontal rules" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      # Header
      Some content
      ---
      More content
      ***
      Final content
      ___
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    descriptions = created.map { |c| c.reload.description }

    # Should have: Header, Some content, More content, Final content
    assert_equal 4, created.size, "Horizontal rules should be skipped"
    assert descriptions.none? { |d| d.strip == "---" }, "--- should not create a Creative"
    assert descriptions.none? { |d| d.strip == "***" }, "*** should not create a Creative"
    assert descriptions.none? { |d| d.strip == "___" }, "___ should not create a Creative"
  end

  test "imports fenced code blocks as single creative with pre/code tags" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      # Header
      ```ruby
      def hello
        puts "world"
      end
      ```
      Some text after
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    # Should have: Header, code block, Some text after
    assert_equal 3, created.size, "Code block should be a single Creative"

    code_creative = created[1].reload
    html = code_creative.description

    assert_includes html, "<pre><code", "Code block should have pre/code tags"
    assert_includes html, 'class="language-ruby"', "Code block should preserve language"
    assert_includes html, "def hello", "Code block should contain the code"
    assert_includes html, "puts", "Code block should contain all lines"
  end

  test "handles code blocks without language specifier" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```
      plain code
      more lines
      ```
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    assert_equal 1, created.size

    html = created.first.reload.description
    assert_includes html, "<pre><code>"
    assert_includes html, "plain code"
    assert_not_includes html, 'class="language-'
  end

  test "escapes html in code blocks" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```html
      <div class="test">Hello</div>
      ```
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    html = created.first.reload.description

    assert_includes html, "&lt;div"
    assert_includes html, "&gt;"
    assert_not_includes html, "<div class=\"test\">"
  end

  test "imports markdown tables as html" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      | Name | Count |
      | ---- | ----- |
      | Alice | 3 |
      | Bob | 5 |
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    table_creative = created.last
    table_creative.reload

    html = table_creative.description
    assert_includes html, "<table>"
    assert_includes html, "Alice"
    assert_includes html, "5"
    assert_includes html, "<table>"
  end

  test "does not convert table syntax inside fenced code blocks" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```
      | key | value |
      | --- | ----- |
      ```

      | Name | Count |
      | ---- | ----- |
      | Alice | 3 |
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    html_fragments = created.map { |creative| creative.reload.description }

    code_block_html = html_fragments.find { |html| html.include?("| key | value |") }
    assert_not_nil code_block_html, "Expected code block content to be preserved"

    table_htmls = html_fragments.select { |html| html.include?("<table>") }
    assert_equal 1, table_htmls.size, "Only actual tables should be converted to HTML"
  end

  test "imports bare reference-style data-URI image definitions as attachments" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    png_b64 = Base64.strict_encode64("\x89PNG\r\n\x1A\n" + "x" * 64)
    markdown = <<~MD
      ![pic][p]

      [p]: data:image/png;base64,#{png_b64}
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    image_creative = created.find { |c| c.reload.description.match?(%r{<img[^>]+/rails/active_storage/}) }
    assert_not_nil image_creative, "Bare reference-style data URI should resolve to an Active Storage blob image"
    assert_no_match(/data:image\/png;base64/, image_creative.description, "Raw data URI must not survive import")
  end

  test "imports angle-bracket reference-style data-URI image definitions as attachments" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    png_b64 = Base64.strict_encode64("\x89PNG\r\n\x1A\n" + "y" * 64)
    markdown = <<~MD
      ![pic][p]

      [p]: <data:image/png;base64,#{png_b64}>
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    image_creative = created.find { |c| c.reload.description.match?(%r{<img[^>]+/rails/active_storage/}) }
    assert_not_nil image_creative, "Angle-bracket reference-style data URI should still resolve to an Active Storage blob image"
    assert_no_match(/data:image\/png;base64/, image_creative.description, "Raw data URI must not survive import")
  end

  test "imports bare reference-style data-URI image with optional title" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    png_b64 = Base64.strict_encode64("\x89PNG\r\n\x1A\n" + "z" * 64)
    markdown = <<~MD
      ![pic][p]

      [p]: data:image/png;base64,#{png_b64} "caption"
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    image_creative = created.find { |c| c.reload.description.match?(%r{<img[^>]+/rails/active_storage/}) }
    assert_not_nil image_creative, "Bare reference-style data URI with title should still resolve to an Active Storage blob image"
    assert_no_match(/data:image\/png;base64/, image_creative.description, "Raw data URI must not survive import")
  end

  test "assigns contiguous sequence to persisted siblings in document order" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      First
      Second
      Third
      Fourth
      Fifth
    MD

    MarkdownImporter.import(markdown, parent: parent, user: user)

    ordered = parent.children.order(:sequence).map { |c| plain_text(c.description) }
    assert_equal %w[First Second Third Fourth Fifth], ordered,
      "Persisted children must sort by sequence in document order (not rely on DB tie-break)"
    assert_equal [ 0, 1, 2, 3, 4 ], parent.children.order(:sequence).map(&:sequence),
      "Imported siblings must get contiguous 0-based sequence values"
  end

  test "assigns per-parent sequence for nested headings" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      # H1
      Alpha
      Beta
      ## H2
      Gamma
      Delta
    MD

    MarkdownImporter.import(markdown, parent: parent, user: user)

    h1 = parent.children.order(:sequence).first
    assert_equal "H1", plain_text(h1.description)
    # Under H1: "Alpha", "Beta", then "H2" — each a distinct sibling in order
    assert_equal %w[Alpha Beta H2], h1.children.order(:sequence).map { |c| plain_text(c.description) }
    assert_equal [ 0, 1, 2 ], h1.children.order(:sequence).map(&:sequence)

    h2 = h1.children.order(:sequence).find { |c| plain_text(c.description) == "H2" }
    assert_equal %w[Gamma Delta], h2.children.order(:sequence).map { |c| plain_text(c.description) }
    assert_equal [ 0, 1 ], h2.children.order(:sequence).map(&:sequence)
  end

  test "appends imported siblings after existing children of the target parent" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    existing = Creative.create!(user: user, parent: parent, description: "Existing", sequence: 0)

    MarkdownImporter.import("Imported one\nImported two\n", parent: parent, user: user)

    ordered = parent.children.order(:sequence).map { |c| plain_text(c.description) }
    assert_equal [ "Existing", "Imported one", "Imported two" ], ordered,
      "Imported nodes must append after pre-existing children, not collide at sequence 0"
    assert_equal existing, parent.children.order(:sequence).first
  end

  test "imports at root level with a nil parent and sequences the root siblings" do
    user = users(:one)
    markdown = <<~MD
      # Root Page
      First child
      Second child
    MD

    # Top-level import (no parent_id) passes parent: nil with create_root: true.
    # Regression guard: create_child must not dereference a nil parent.
    created = MarkdownImporter.import(markdown, parent: nil, user: user, create_root: true)

    root = created.first
    assert_nil root.parent, "create_root import must produce a top-level creative"
    assert_equal "Root Page", plain_text(root.description)

    ordered = root.children.order(:sequence).map { |c| plain_text(c.description) }
    assert_equal [ "First child", "Second child" ], ordered
    assert_equal [ 0, 1 ], root.children.order(:sequence).pluck(:sequence)
  end

  private

  # Extract visible text via a real HTML parser; a single-pass tag-strip regex
  # is incomplete (nested tags like `<<b>b>` slip through) — CodeQL flags it.
  def plain_text(html)
    Nokogiri::HTML.fragment(html.to_s).text.strip
  end
end
