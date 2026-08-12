require "test_helper"

class CreativesHelperTest < ActionView::TestCase
  include Collavre::CreativesHelper
  test "markdown_links_to_html converts markdown link to HTML" do
    input = "Check [link](https://example.com)"
    result = markdown_links_to_html(input)
    assert_includes result, '<a href="https://example.com">link</a>'
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
    assert_includes html, "<strong>bold</strong>"
    back = Collavre::MarkdownConverter.html_to_markdown(html)
    assert_equal "This is **bold** text", back
  end

  test "bold markdown spanning lines converts to html" do
    md = "This is **bold\ntext** example"
    html = markdown_links_to_html(md)
    assert_includes html, "<strong>bold"
    assert_includes html, "text</strong>"
  end

  test "html bold with attributes converts to markdown" do
    input = '<strong class="highlight">bold</strong> text'
    expected = "**bold** text"
    assert_equal expected, Collavre::MarkdownConverter.html_to_markdown(input)
  end

  test "escaped characters round trip" do
    md = "A \\*star\\* \\-dash\\- \\#hash\\# \\~tilde\\~ \\+plus\\+ example"
    html = markdown_links_to_html(md)
    assert_includes html, "star"
    assert_includes html, "dash"
  end

  test "base64 image link converts" do
    md = "Image: ![alt](data:image/png;base64,aGk=)"
    html = markdown_links_to_html(md)
    assert_match(/<img[^>]+src=\"[^\"]*\"[^>]*alt=\"alt\"[^>]*\/?>/, html)
    back = Collavre::MarkdownConverter.html_to_markdown(html)
    assert_equal md, back
  end

  test "reference style base64 image converts" do
    md = "Look ![][img1]\n\n[img1]: <data:image/png;base64,aGk=>"
    html = markdown_links_to_html(md)
    assert_match(/<img[^>]+src=\"[^\"]*\"[^>]*\/?>/, html)
    back = Collavre::MarkdownConverter.html_to_markdown(html)
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
    assert_equal expected, Collavre::MarkdownConverter.html_to_markdown(html.strip)
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
    assert_equal expected, Collavre::MarkdownConverter.html_to_markdown(html.strip)
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

      heading = parent.children.detect { |child| child.description.to_s.include?("Bold Heading") }
      paragraph = parent.descendants.detect { |desc| desc.description.to_s.include?("Regular") }

      assert_not_nil heading, "Expected heading creative to be created"
      assert_includes heading.description.to_s, "<strong>Bold Heading</strong>"

      assert_not_nil paragraph, "Expected paragraph creative to be created"
      assert_includes paragraph.description.to_s, "<strong>bold</strong>"
    ensure
      created.each(&:destroy)
      parent.destroy
    end
  end
  test "render_tags strips html from label names" do
    label = Label.new(id: 1, creative: Creative.new(description: "<b>HTML</b> Tag"))
    html = render_tags([ label ], nil, true)
    assert_includes html, ">#HTML Tag</a>", "Link text should be stripped"
    assert_includes html, "title=\"HTML Tag\"", "Title attribute should be stripped"
  end


  test "render_progress_value reads the completion mark once per view context" do
    calls = 0

    Collavre::SystemSetting.stub(:completion_mark, -> { calls += 1; "✓" }) do
      render_progress_value(1)
      render_progress_value(0.5)
      render_progress_value(1)
    end

    assert_equal 1, calls
  end

  test "render_progress_control shows a checkbox for writable binary leaf progress" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Checkbox leaf", progress: 0)

    Current.set(user: user) do
      html = render_progress_control(creative, 0, has_children: false, can_write: true)

      assert_includes html, 'data-progress-toggle="true"'
      assert_includes html, 'type="checkbox"'
      refute_includes html, "creative-progress-incomplete"
    end
  end

  test "render_progress_control keeps percentages for non-binary leaves and parents" do
    user = users(:one)
    leaf = Creative.create!(user: user, description: "Partial leaf", progress: 0.5)
    parent = Creative.create!(user: user, description: "Parent", progress: 0)

    Current.set(user: user) do
      partial_html = render_progress_control(leaf, 0.5, has_children: false, can_write: true)
      parent_html = render_progress_control(parent, 0, has_children: true, can_write: true)

      assert_includes partial_html, "50%"
      refute_includes partial_html, "progress-toggle-checkbox"
      assert_includes parent_html, "0%"
      refute_includes parent_html, "progress-toggle-checkbox"
    end
  end

  test "render_progress_control keeps percentages in select mode and for read-only users" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Non interactive leaf", progress: 1)

    Current.set(user: user) do
      select_mode_html = render_progress_control(creative, 1, has_children: false, can_write: true, select_mode: true)
      read_only_html = render_progress_control(creative, 1, has_children: false, can_write: false)

      refute_includes select_mode_html, "progress-toggle-checkbox"
      refute_includes read_only_html, "progress-toggle-checkbox"
    end
  end

  test "render_progress_toggle renders the completion mark alongside the checkbox" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Completed leaf", progress: 1)

    Current.set(user: user) do
      Collavre::SystemSetting.stub(:completion_mark, "✓") do
        html = render_progress_control(creative, 1, has_children: false, can_write: true)

        assert_includes html, 'data-current-progress="1"'
        assert_includes html, "progress-toggle-mark"
        assert_includes html, "✓"
        # The checkbox stays the accessible control; CSS is what hides it behind
        # the mark until the row is hovered or focused.
        assert_includes html, "progress-toggle-checkbox"
        assert_includes html, 'checked="checked"'
      end
    end
  end

  test "render_progress_toggle falls back to a non-breaking space for a blank completion mark" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Quietly completed leaf", progress: 1)

    Current.set(user: user) do
      Collavre::SystemSetting.stub(:completion_mark, "") do
        html = render_progress_control(creative, 1, has_children: false, can_write: true)

        assert_includes html, %(<span class="progress-toggle-mark" aria-hidden="true"> </span>)
      end
    end
  end

  test "render_progress_toggle keeps the checkbox reachable by keyboard" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "Keyboard leaf", progress: 0)

    Current.set(user: user) do
      html = render_progress_control(creative, 0, has_children: false, can_write: true)

      refute_includes html, 'tabindex="-1"'
    end
  end

  test "render_creative_tree_markdown includes children of origin for linked creatives" do
    user = users(:one)

    # Origin Tree
    origin_root = Creative.create!(user: user, description: "Origin Root")
    origin_child = Creative.create!(user: user, description: "Origin Child", parent: origin_root)

    # Linked Creative pointing to Origin Root
    linked_root = Creative.create!(user: user, description: "Linked Root", origin: origin_root)

    Current.set(user: user) do
      # Provide the linked creative to the helper
      markdown = render_creative_tree_markdown([ linked_root ], 1)

      # The output should contain the Linked Root description (which comes from Origin)
      assert_match(/Origin Root/, markdown)

      # CRITICAL: The output should ALSO contain the Origin Child description
      # because we should traverse the children of the origin.
      assert_match(/Origin Child/, markdown)
    end
  end

  # max_depth tests for render_creative_tree_markdown

  test "render_creative_tree_markdown with max_depth limits tree depth" do
    user = users(:one)

    root = Collavre::Creative.create!(description: "Root", user: user)
    child = Collavre::Creative.create!(description: "Child", parent: root, user: user)
    Collavre::Creative.create!(description: "Grandchild", parent: child, user: user)

    Current.set(user: user) do
      # max_depth: 1 → only root (level 1), no children
      md = render_creative_tree_markdown([ root ], 1, false, max_depth: 1)
      assert_match(/Root/, md)
      assert_no_match(/Child/, md)

      # max_depth: 2 → root + children, no grandchildren
      md = render_creative_tree_markdown([ root ], 1, false, max_depth: 2)
      assert_match(/Root/, md)
      assert_match(/Child/, md)
      assert_no_match(/Grandchild/, md)

      # max_depth: 3 → root + children + grandchildren
      md = render_creative_tree_markdown([ root ], 1, false, max_depth: 3)
      assert_match(/Root/, md)
      assert_match(/Child/, md)
      assert_match(/Grandchild/, md)
    end
  end

  test "render_creative_tree_markdown without max_depth includes all levels" do
    user = users(:one)

    root = Collavre::Creative.create!(description: "Root", user: user)
    child = Collavre::Creative.create!(description: "Child", parent: root, user: user)
    Collavre::Creative.create!(description: "Grandchild", parent: child, user: user)

    Current.set(user: user) do
      md = render_creative_tree_markdown([ root ], 1, false)
      assert_match(/Root/, md)
      assert_match(/Child/, md)
      assert_match(/Grandchild/, md)
    end
  end
end
