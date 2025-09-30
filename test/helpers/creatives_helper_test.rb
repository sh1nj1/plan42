require "test_helper"

class CreativesHelperTest < ActionView::TestCase
  include CreativesHelper
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
      | A \| B | Either A or B |
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

    markdown = render_creative_tree_markdown([creative])

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
end
