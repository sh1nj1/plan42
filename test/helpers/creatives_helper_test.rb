require "test_helper"

class CreativesHelperTest < ActionView::TestCase
  include CreativesHelper
  include ApplicationHelper

  def turbo_stream_from(*)
    "".html_safe
  end
  test "markdown_links_to_html converts markdown link to HTML" do
    input = "Check [link](https://example.com)"
    expected = "Check <a href=\"https://example.com\">link</a>"
    assert_equal expected, markdown_links_to_html(input)
  end

  test "html_links_to_markdown converts HTML link to markdown" do
    input = "See <a href=\"https://example.com\">example</a> for details"
    expected = "See [example](https://example.com) for details"
    assert_equal expected, html_links_to_markdown(input)
  end

  test "markdown list items are single line" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "<div>Item</div>\n")
    markdown = render_creative_tree_markdown([ creative ], 5)
    assert_equal "* Item\n", markdown
  end

  test "bold markdown converts to html and back" do
    md = "This is **bold** text"
    html = markdown_links_to_html(md)
    assert_equal "This is <strong>bold</strong> text", html
    back = html_links_to_markdown(html)
    assert_equal "This is **bold** text", back
  end

  test "bold markdown spanning lines converts to html" do
    md = "This is **bold\ntext** example"
    html = markdown_links_to_html(md)
    assert_equal "This is <strong>bold\ntext</strong> example", html
  end

  test "html bold with attributes converts to markdown" do
    input = '<strong class="highlight">bold</strong> text'
    expected = "**bold** text"
    assert_equal expected, html_links_to_markdown(input)
  end

  test "escaped characters round trip" do
    md = "A \\*star\\* \\-dash\\- \\#hash\\# \\~tilde\\~ \\+plus\\+ example"
    html = markdown_links_to_html(md)
    assert_equal "A *star* -dash- #hash# ~tilde~ +plus+ example", html
    back = html_links_to_markdown(html)
    assert_equal md, back
  end

  test "base64 image link converts" do
    md = "Image: ![alt](data:image/png;base64,aGk=)"
    html = markdown_links_to_html(md)
    assert_match(/<action-text-attachment[^>]+content-type=\"image\/png\"[^>]+caption=\"alt\"[^>]*>/, html)
    back = html_links_to_markdown(html)
    assert_equal md, back
  end

  test "reference style base64 image converts" do
    md = "Look ![][img1]\n\n[img1]: <data:image/png;base64,aGk=>"
    html = markdown_links_to_html(md)
    assert_match(/<action-text-attachment[^>]+content-type=\"image\/png\"[^>]*>/, html)
    back = html_links_to_markdown(html)
    assert_equal "Look ![](data:image/png;base64,aGk=)", back
  end

  test "html table converts to markdown" do
    html = <<~HTML
      <table>
        <thead>
          <tr>
            <th style="text-align: left;">Name</th>
            <th style="text-align: center;">Count</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Alice</td>
            <td>3</td>
          </tr>
          <tr>
            <td>Bob</td>
            <td>5</td>
          </tr>
        </tbody>
      </table>
    HTML
    expected = <<~MD.strip
      | Name | Count |
      | :--- | :---: |
      | Alice | 3 |
      | Bob | 5 |
    MD
    assert_equal expected, html_links_to_markdown(html.strip)
  end

  test "html table escapes pipe characters in cells" do
    html = <<~HTML
      <table>
        <thead>
          <tr>
            <th>Expression</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>A | B</td>
            <td>Either A or B</td>
          </tr>
        </tbody>
      </table>
    HTML
    expected = <<~MD.strip
      | Expression | Description |
      | --- | --- |
      | A \\| B | Either A or B |
    MD
    assert_equal expected, html_links_to_markdown(html.strip)
  end

  test "render_creative_tree_markdown exports tables without heading prefix" do
    user = users(:one)
    description = <<~HTML
      <div class="trix-content">
        <div>
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Count</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Alice</td>
                <td>3</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    HTML
    creative = Creative.create!(user: user, description: description)

    markdown = render_creative_tree_markdown([ creative ])

    expected = <<~MD
      | Name | Count |
      | --- | --- |
      | Alice | 3 |
    MD
    expected << "\n"

    assert_equal expected, markdown
  end

  test "expanded_from_expanded_state defaults to collapsed" do
    assert_not expanded_from_expanded_state(1, {})
  end

  test "expanded_from_expanded_state returns true when expanded" do
    assert expanded_from_expanded_state(1, { "1" => true })
  end

  test "markdown importer preserves bold formatting" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ## **Bold Heading**
      Regular **bold** text
    MD

    created = []

    begin
      created = MarkdownImporter.import(markdown, parent: parent, user: user)

      heading = parent.children.detect { |child| child.description.body.to_html.include?("Bold Heading") }
      paragraph = parent.descendants.detect { |desc| desc.description.body.to_html.include?("Regular") }

      assert_not_nil heading, "Expected heading creative to be created"
      assert_includes heading.description.body.to_html, "<strong>Bold Heading</strong>"

      assert_not_nil paragraph, "Expected paragraph creative to be created"
      assert_includes paragraph.description.body.to_html, "<strong>bold</strong>"
    ensure
      created.each(&:destroy)
      parent.destroy
    end
  end

  test "render_creative_tree avoids infinite recursion when linked creatives appear in search results" do
    owner = users(:one)
    Current.session = OpenStruct.new(user: owner)

    root = Creative.create!(user: owner, description: "Root", sequence: 0)
    linked = Creative.create!(origin: root, user: owner, parent: root, sequence: 0)

    @expanded_state_map = {}
    @controller.params = ActionController::Parameters.new(search: "Linked")

    output = render_creative_tree([ linked ], 1, select_mode: false, max_level: User::DEFAULT_DISPLAY_LEVEL)

    assert_includes output, "<creative-tree-row"
    assert_equal 1, output.scan("<creative-tree-row").length
  ensure
    Current.reset
  end
end
