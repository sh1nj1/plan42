require "test_helper"

class ProgressFilterComponentTest < ViewComponent::TestCase
  COMMENT_STATE = { name: "Chat", value: :comment }.freeze

  test "renders a button per state with the Stimulus filter param" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil, states: [ COMMENT_STATE ]))

    assert_selector "button.progress-filter-btn[data-progress-filter-filter-param='comment']", text: "Chat"
    assert_selector "button[data-action='click->progress-filter#apply']"
  end

  test "marks the button active when it matches the current state" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: :comment, states: [ COMMENT_STATE ]))

    assert_selector "button.progress-filter-btn.active"
  end

  test "leaves the button inactive when it does not match the current state" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil, states: [ COMMENT_STATE ]))

    assert_no_selector "button.progress-filter-btn.active"
  end

  test "exposes the creative index path so the filter can navigate off other pages" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil, states: [ COMMENT_STATE ]))

    assert_selector "[data-controller='progress-filter'][data-progress-filter-index-path-value='/creatives']"
  end

  test "reports whether the current page is the creative index" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil, states: [ COMMENT_STATE ]))

    # The component test controller is not creatives#index.
    assert_selector "[data-progress-filter-on-index-value='false']"
  end

  test "renders nothing but the wrapper when no states are given" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil))

    assert_selector "div.progress-filter-group"
    assert_no_selector "button"
  end

  test "filter_state_key namespaces progress values and passes others through" do
    component = Collavre::ProgressFilterComponent.new(current_state: nil)

    assert_equal "progress:all", component.filter_state_key(:all)
    assert_equal "progress:complete", component.filter_state_key(:complete)
    assert_equal "progress:incomplete", component.filter_state_key(:incomplete)
    assert_equal "comment", component.filter_state_key(:comment)
  end

  test "renders the state key the client uses to re-apply the active class" do
    render_inline(Collavre::ProgressFilterComponent.new(current_state: nil, states: [ COMMENT_STATE ]))

    assert_selector "button[data-filter-state='comment']"
  end

  test "renders the progress state key for a progress state" do
    render_inline(
      Collavre::ProgressFilterComponent.new(
        current_state: nil,
        states: [ { name: "Done", value: :complete } ]
      )
    )

    assert_selector "button[data-filter-state='progress:complete']"
  end
end
