require "test_helper"

class CreativeReactionFilterTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "reaction-filter@example.com", password: TEST_PASSWORD, name: "Reaction Filter")
    @other = users(:two)
    @root = Creative.create!(user: @user, description: "Reaction root")
    @matched = Creative.create!(user: @user, parent: @root, description: "Marked child", progress: 0)
    @plain = Creative.create!(user: @user, description: "Plain child 👍")
    @private = Creative.create!(user: @other, description: "Private marked child")
    [ @matched, @private ].each do |creative|
      2.times do
        comment = Comment.create!(creative: creative, user: creative.user, content: "Message")
        [ @user, @other ].each do |user|
          Collavre::CommentReaction.create!(comment: comment, user: user, emoji: "👍")
        end
      end
    end
    sign_in_as(@user)
  end

  test "reaction alone returns only matching accessible creatives without duplicates" do
    get creatives_path(format: :json, reaction_emoji: "👍")
    assert_response :success
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
  end

  test "private reactions are hidden from other users with creative access" do
    @matched.comments.update_all(private: true, user_id: @other.id)

    get creatives_path(format: :json, reaction_emoji: "👍")

    assert_response :success
    assert_empty JSON.parse(response.body).fetch("creatives")
  end

  test "matching parent and child render once each in flat reaction results" do
    comment = Comment.create!(creative: @root, user: @user, content: "Marked parent")
    Collavre::CommentReaction.create!(comment: comment, user: @user, emoji: "👍")

    get creatives_path(format: :json, reaction_emoji: "👍")

    assert_response :success
    nodes = JSON.parse(response.body).fetch("creatives")
    assert_equal [ @root.id, @matched.id ].sort, nodes.pluck("id").sort
    nodes.each do |node|
      assert_equal false, node.fetch("has_children")
      assert_nil node.fetch("children_container")
    end
  end

  test "authors can filter by reactions on their private comments" do
    @matched.comments.update_all(private: true)

    get creatives_path(format: :json, reaction_emoji: "👍")

    assert_response :success
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
  end

  test "approvers can filter by reactions on private comments" do
    @matched.comments.update_all(private: true, user_id: @other.id, approver_id: @user.id)

    get creatives_path(format: :json, reaction_emoji: "👍")

    assert_response :success
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
  end

  test "anonymous reaction filtering only matches public comments" do
    scope = Creative.where(id: @matched.id)
    pipeline = Collavre::Creatives::FilterPipeline.new(user: nil, params: { reaction_emoji: "👍" }, scope: scope)
    assert_equal [ @matched.id ], pipeline.matched_ids

    @matched.comments.update_all(private: true)

    assert_empty pipeline.matched_ids
    filter = Collavre::Creatives::Filters::ReactionFilter.new(params: { reaction_emoji: "👍" }, scope: scope)
    assert_empty filter.match
  end

  test "reaction intersects existing search and progress filters" do
    get creatives_path(format: :json, reaction_emoji: "👍", search: "Marked", max_progress: 0)
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
    get creatives_path(format: :json, reaction_emoji: "👍", search: "Plain")
    assert_empty JSON.parse(response.body).fetch("creatives")
    get creatives_path(format: :json, reaction_emoji: "👍", min_progress: 1)
    assert_empty JSON.parse(response.body).fetch("creatives")
  end

  test "unmatched and SQL-like emoji values do not match" do
    [ "🎉", "%' OR 1=1 --" ].each do |emoji|
      get creatives_path(format: :json, reaction_emoji: emoji)
      assert_empty JSON.parse(response.body).fetch("creatives")
    end
  end

  test "other users reactions match and deleting the last reaction removes the match" do
    reactions = Collavre::CommentReaction.where(comment_id: @matched.comments.select(:id))
    reactions.where(user: @user).destroy_all
    get creatives_path(format: :json, reaction_emoji: "👍")
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
    reactions.destroy_all
    get creatives_path(format: :json, reaction_emoji: "👍")
    assert_empty JSON.parse(response.body).fetch("creatives")
  end

  test "reaction composes with paginated chats" do
    get creatives_path(format: :json, reaction_emoji: "👍", comment: "true", per_page: 1)
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
    get creatives_path(format: :json, reaction_emoji: "👍", comment: "true", per_page: 1, page: 2)
    assert_empty JSON.parse(response.body).fetch("creatives")
  end

  test "archived reaction matches are hidden unless requested" do
    @matched.update!(archived_at: Time.current)
    get creatives_path(format: :json, reaction_emoji: "👍")
    assert_empty JSON.parse(response.body).fetch("creatives")
    get creatives_path(format: :json, reaction_emoji: "👍", show_archived: "true")
    assert_equal [ @matched.id ], JSON.parse(response.body).fetch("creatives").pluck("id")
  end

  test "chat picker retains the shared emoji buttons and action" do
    html = Collavre::ApplicationController.render(partial: "collavre/comments/reaction_picker")
    fragment = Nokogiri::HTML.fragment(html)
    buttons = fragment.css("#global-reaction-picker .comment-reaction-picker-emoji")
    assert_equal 10, buttons.size
    assert_equal [ "click->reaction-picker#select" ], buttons.map { |button| button["data-action"] }.uniq
    assert_empty fragment.css("[data-filter-state]")
  end

  test "blank reaction is inactive" do
    refute Collavre::Creatives::Filters::ReactionFilter.new(params: { reaction_emoji: "" }, scope: Creative.all).active?
    refute Collavre::Creatives::FilterState.new({ reaction_emoji: "" }).active?
  end

  test "html preserves reaction for the tree fetch and renders shared buttons" do
    get creatives_path(reaction_emoji: "👍")
    assert_response :success
    assert_select "[data-filter-state='reaction:👍'].active[aria-pressed='true']"
    assert_select "[data-filter-state='any-filter'].active"
    assert_select "[data-action='click->search-popup#applyReactionFilter']", count: 10
    assert_select "[data-creatives--tree-url-value]" do |nodes|
      url = URI.parse(nodes.first["data-creatives--tree-url-value"])
      assert_equal "👍", Rack::Utils.parse_query(url.query)["reaction_emoji"]
    end
  end

  test "scope excludes reactions outside the requested subtree" do
    get creatives_path(format: :json, id: @plain.id, reaction_emoji: "👍")
    assert_empty JSON.parse(response.body).fetch("creatives")
  end

  test "tree mode retains matching creative ancestors" do
    get creatives_path(format: :json, reaction_emoji: "👍", search_mode: "tree")
    nodes = JSON.parse(response.body).fetch("creatives")
    assert_equal [ @root.id ], nodes.pluck("id")
    assert_equal true, nodes.first.fetch("has_children")
    assert_equal [ @matched.id ], nodes.first.fetch("children_container").fetch("nodes").pluck("id")
  end
end
