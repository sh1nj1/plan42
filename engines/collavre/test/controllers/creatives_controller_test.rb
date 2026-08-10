require "test_helper"

class CreativesControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(creative_workspace_enabled: true)
    sign_in_as(users(:one), password: "password")
  end

  def creative_tree_stream_selector
    signed_name = Turbo::StreamsChannel.signed_stream_name([ users(:one), :creative_tree ])
    "turbo-cable-stream-source[signed-stream-name='#{signed_name}']"
  end

  def last_visited_creative_token
    response.body.match(/data-(?:workspace-tree|last-visited-creative)-last-visited-creative-visit-token-value="([^"]+)"/)[1]
  end

  test "opening a readable creative remembers it as the user's last visited creative" do
    user = users(:one)
    creative = creatives(:root_parent)
    user.update!(last_visited_creative_id: nil)

    get creatives_path(id: creative.id), headers: { "Turbo-Frame" => "creative-workspace-content" }

    assert_response :success
    assert_equal creative, user.reload.last_visited_creative
    assert_equal 1, user.last_visited_creative_visit_sequence
  end

  test "a headerless Creative navigation allocates its sequence while holding the user lock" do
    user = users(:one)
    first_creative = creatives(:root_parent)
    second_creative = creatives(:unconvert_target)

    get creatives_path(id: first_creative.id)
    get creatives_path(id: second_creative.id)

    assert_response :success
    assert_equal second_creative, user.reload.last_visited_creative
    assert_equal 2, user.last_visited_creative_visit_sequence
  end

  test "storage-disabled tabs receive distinct server-allocated visit sequences" do
    user = users(:one)
    first_creative = creatives(:root_parent)
    second_creative = creatives(:unconvert_target)

    get creatives_path(id: first_creative.id)
    visit_token = last_visited_creative_token

    get creatives_path(id: second_creative.id), headers: {
      "X-Collavre-Last-Visited-Creative-Token" => visit_token
    }

    assert_response :success
    assert_equal second_creative, user.reload.last_visited_creative
    assert_equal 2, user.last_visited_creative_visit_sequence
  end

  test "server-issued sequences preserve navigation order when requests arrive out of order" do
    user = users(:one)
    earlier_creative = creatives(:root_parent)
    later_creative = creatives(:unconvert_target)

    get creatives_path(id: earlier_creative.id)
    visit_token = last_visited_creative_token

    patch next_last_visited_sequence_creatives_path, as: :json
    earlier_sequence = response.parsed_body.fetch("sequence")
    patch next_last_visited_sequence_creatives_path, as: :json
    later_sequence = response.parsed_body.fetch("sequence")

    get creatives_path(id: later_creative.id), headers: {
      "X-Collavre-Last-Visited-Creative-Token" => visit_token,
      "X-Collavre-Last-Visited-Creative-Sequence" => later_sequence.to_s
    }
    patch remember_last_visited_creative_path(earlier_creative),
      params: { visit_token: visit_token },
      headers: { "X-Collavre-Last-Visited-Creative-Sequence" => earlier_sequence.to_s },
      as: :json

    assert_response :no_content
    assert_equal later_creative, user.reload.last_visited_creative
    assert_equal later_sequence, user.last_visited_creative_visit_sequence
  end

  test "issuing a visit sequence requires an authenticated user" do
    delete session_path

    patch next_last_visited_sequence_creatives_path, as: :json

    assert_response :forbidden
  end

  test "an earlier request from another browser session cannot overwrite a later visit" do
    user = users(:one)
    earlier_creative = creatives(:root_parent)
    later_creative = creatives(:unconvert_target)
    earlier_received_at = 2.minutes.ago

    user.update!(
      last_visited_creative: later_creative,
      last_visited_creative_at: 1.minute.ago,
      last_visited_creative_client_id: "second-browser",
      last_visited_creative_visit_sequence: 1
    )

    Collavre::CreativesController.new.send(
      :remember_last_visited_creative,
      earlier_creative,
      client_id: "first-browser",
      sequence: 1,
      received_at: earlier_received_at
    )

    assert_equal later_creative, user.reload.last_visited_creative
    assert_equal "second-browser", user.last_visited_creative_client_id
  end

  test "prefetching a readable creative does not remember it as the user's last visited creative" do
    user = users(:one)
    creative = creatives(:root_parent)
    user.update!(last_visited_creative_id: nil)

    get creatives_path(id: creative.id), headers: {
      "Turbo-Frame" => "creative-workspace-content",
      "X-Sec-Purpose" => "prefetch"
    }

    assert_response :success
    assert_nil user.reload.last_visited_creative
  end

  test "a prefetch HEAD request for a creative does not remember it as the user's last visited creative" do
    user = users(:one)
    creative = creatives(:root_parent)
    user.update!(last_visited_creative_id: nil)

    head creatives_path(id: creative.id), headers: { "X-Sec-Purpose" => "prefetch" }

    assert_response :success
    assert_nil user.reload.last_visited_creative
  end

  test "opening an inaccessible creative does not replace the last visited creative" do
    user = users(:one)
    remembered_creative = creatives(:root_parent)
    inaccessible_creative = Creative.create!(user: users(:two), description: "Private workspace creative")
    user.update!(last_visited_creative: remembered_creative)

    get creatives_path(id: inaccessible_creative.id), headers: { "Turbo-Frame" => "creative-workspace-content" }

    assert_response :success
    assert_equal remembered_creative, user.reload.last_visited_creative
  end

  test "remembering a creative restored from browser history updates the last visited creative" do
    user = users(:one)
    creative = creatives(:root_parent)

    get creatives_path(id: creative.id)
    visit_token = last_visited_creative_token
    user.update!(last_visited_creative_id: nil)

    patch remember_last_visited_creative_path(creative),
      params: { visit_token: visit_token },
      headers: { "X-Collavre-Last-Visited-Creative-Sequence" => "2" },
      as: :json

    assert_response :no_content
    assert_equal creative, user.reload.last_visited_creative
  end

  test "a storage-disabled browser history restore receives a server-allocated sequence" do
    user = users(:one)
    creative = creatives(:root_parent)

    get creatives_path(id: creative.id)
    visit_token = last_visited_creative_token
    user.update!(last_visited_creative_id: nil)

    patch remember_last_visited_creative_path(creative),
      params: { visit_token: visit_token },
      as: :json

    assert_response :no_content
    assert_equal creative, user.reload.last_visited_creative
    assert_equal 2, user.last_visited_creative_visit_sequence
  end

  test "a delayed restored visit cannot overwrite a later Creative navigation" do
    user = users(:one)
    newer_creative = creatives(:root_parent)
    restored_creative = creatives(:unconvert_target)

    get creatives_path(id: restored_creative.id)
    restored_visit_token = last_visited_creative_token

    get creatives_path(id: newer_creative.id), headers: {
      "X-Collavre-Last-Visited-Creative-Token" => restored_visit_token,
      "X-Collavre-Last-Visited-Creative-Sequence" => "2"
    }

    patch remember_last_visited_creative_path(restored_creative),
      params: { visit_token: restored_visit_token },
      headers: { "X-Collavre-Last-Visited-Creative-Sequence" => "1" },
      as: :json

    assert_response :no_content
    assert_equal newer_creative, user.reload.last_visited_creative
    assert_equal 2, user.last_visited_creative_visit_sequence
  end

  test "a browser history restore supersedes the Creative visited before it" do
    user = users(:one)
    restored_creative = creatives(:root_parent)
    newer_creative = creatives(:unconvert_target)

    get creatives_path(id: restored_creative.id)
    restored_visit_token = last_visited_creative_token

    get creatives_path(id: newer_creative.id), headers: {
      "X-Collavre-Last-Visited-Creative-Token" => restored_visit_token,
      "X-Collavre-Last-Visited-Creative-Sequence" => "2"
    }

    patch remember_last_visited_creative_path(restored_creative),
      params: { visit_token: restored_visit_token },
      headers: { "X-Collavre-Last-Visited-Creative-Sequence" => "3" },
      as: :json

    assert_response :no_content
    assert_equal restored_creative, user.reload.last_visited_creative
    assert_equal 3, user.last_visited_creative_visit_sequence
  end

  test "rejects unsigned restored visit tokens" do
    user = users(:one)
    previous_creative = creatives(:root_parent)
    visited_creative = creatives(:unconvert_target)
    user.update!(last_visited_creative: previous_creative)

    patch remember_last_visited_creative_path(visited_creative), params: { visit_token: "forged" }, as: :json

    assert_response :unprocessable_entity
    assert_equal previous_creative, user.reload.last_visited_creative
  end

  test "rejects a restored visit token for another Creative" do
    token_creative = creatives(:root_parent)
    visited_creative = creatives(:unconvert_target)

    get creatives_path(id: token_creative.id)
    visit_token = last_visited_creative_token

    patch remember_last_visited_creative_path(visited_creative),
      params: { visit_token: visit_token },
      headers: { "X-Collavre-Last-Visited-Creative-Sequence" => "2" },
      as: :json

    assert_response :unprocessable_entity
    assert_equal token_creative, users(:one).reload.last_visited_creative
  end

  test "remembering an inaccessible browser history creative preserves the current last visit" do
    user = users(:one)
    remembered_creative = creatives(:root_parent)
    inaccessible_creative = Creative.create!(user: users(:two), description: "Private workspace creative")
    user.update!(last_visited_creative: remembered_creative)

    patch remember_last_visited_creative_path(inaccessible_creative), as: :json

    assert_response :forbidden
    assert_equal remembered_creative, user.reload.last_visited_creative
  end

  test "creative workspace is disabled by default" do
    users(:one).update!(creative_workspace_enabled: false)
    creative = creatives(:root_parent)

    get creatives_path(id: creative.id)

    assert_response :success
    assert_select "body.creative-workspace", count: 0
    assert_select ".creative-workspace-shell", count: 0
    assert_select "#creative-workspace-tree", count: 0
    assert_select "turbo-frame#creative-workspace-content", count: 0
    assert_select "[data-workspace-navigation-state]", count: 0
    assert_select "[data-controller='last-visited-creative'][data-last-visited-creative-creative-id-value='#{creative.id}'][data-last-visited-creative-visit-token-value]"
    assert_select "#comments-popup[data-docked='false']", count: 1
    assert_select creative_tree_stream_selector, count: 1
  end

  test "creative pages render the three-column workspace shell" do
    creative = creatives(:root_parent)

    get creatives_path(id: creative.id)

    assert_response :success
    assert_select "body.creative-workspace"
    assert_select ".creative-workspace-shell"
    assert_select "#creative-workspace-tree"
    assert_select "[data-controller='workspace-tree'][data-workspace-tree-last-visited-creative-visit-token-value]"
    assert_select "[data-controller='workspace-tree'][data-workspace-tree-last-visited-creative-visit-sequence-value]"
    assert_select "[data-controller='last-visited-creative']", count: 0
    assert_select "turbo-frame#creative-workspace-content:not([target]) [data-workspace-navigation-state][data-creative-id='#{creative.id}']"
    assert_select "turbo-frame#creative-workspace-content [data-workspace-navigation-state][data-last-visited-creative-visit-token][data-last-visited-creative-visit-sequence]"
    assert_select "form[data-turbo-frame='_top'][action='#{slide_view_creative_path(creative)}']"
    assert_select "#comments-popup[data-docked='true'][data-creative-id='#{creative.id}']"
    assert_select ".creative-workspace-shell #{creative_tree_stream_selector}", count: 1
    # The stream source must not be a direct grid child of the shell: grid
    # auto-placement would give it its own implicit row and push all three
    # columns down, leaving a blank band under the top nav.
    assert_select ".creative-workspace-shell > #{creative_tree_stream_selector}", count: 0
    assert_select ".creative-workspace-tree-region #{creative_tree_stream_selector}", count: 1
    assert_select "turbo-frame#creative-workspace-content #{creative_tree_stream_selector}", count: 0
  end

  test "workspace breadcrumb root and ancestor links advance browser history" do
    ancestor = creatives(:unconvert_target)
    child = creatives(:unconvert_child_two)

    get creatives_path(id: child.id)

    assert_response :success
    assert_select "a.creative-breadcrumb-link[href='#{creatives_path}'][data-turbo-action='advance']"
    assert_select "a.creative-breadcrumb-link[href='#{creative_path(ancestor)}'][data-turbo-action='advance'][data-turbo-prefetch='false']"
    assert_select "a.creative-breadcrumb-current[href='#{creative_path(child)}'][data-turbo-action='replace'][data-turbo-prefetch='false']"
  end

  test "workspace tree JSON returns collapsed branches without leaf roots" do
    branch = Creative.create!(user: users(:one), description: "Workspace branch")
    child = Creative.create!(user: users(:one), parent: branch, description: "Workspace child")
    Creative.create!(user: users(:one), parent: child, description: "Workspace leaf")
    leaf = Creative.create!(user: users(:one), description: "Workspace leaf")

    get creatives_path(format: :json, workspace_tree: 1)

    assert_response :success
    payload = JSON.parse(response.body)
    ids = payload.fetch("creatives").pluck("id")
    assert_includes ids, branch.id
    refute_includes ids, leaf.id
    branch_payload = payload.fetch("creatives").find { |node| node.fetch("id") == branch.id }
    assert_equal creatives_path(id: branch.id), branch_payload.fetch("url")
    assert_equal branch.creative_snippet, branch_payload.fetch("snippet")
    assert branch_payload.fetch("can_comment")
    assert branch_payload.fetch("has_children")
    assert_empty branch_payload.fetch("children")
    assert_equal "no-cache", response.headers["Cache-Control"]

    get creatives_path(format: :json, workspace_tree: 1, expand: [ branch.id ])

    assert_response :success
    expanded_branch = JSON.parse(response.body).fetch("creatives").find { |node| node.fetch("id") == branch.id }
    assert_equal [ child.id ], expanded_branch.fetch("children").pluck("id")
  end

  test "workspace tree JSON ignores invalid and excessive expansion ids" do
    branch = Creative.create!(user: users(:one), description: "Limited branch")
    child = Creative.create!(user: users(:one), parent: branch, description: "Limited child")
    Creative.create!(user: users(:one), parent: child, description: "Limited leaf")
    excessive_ids = Array.new(Collavre::CreativesController::WORKSPACE_TREE_EXPANSION_LIMIT) { |index| 1_000_000 + index }

    get creatives_path(
      format: :json,
      workspace_tree: 1,
      expand: [ "invalid", *excessive_ids, branch.id ]
    )

    assert_response :success
    branch_payload = JSON.parse(response.body).fetch("creatives").find { |node| node.fetch("id") == branch.id }
    assert_empty branch_payload.fetch("children")
  end

  test "workspace frame requests render only the replaceable creative content" do
    creative = creatives(:root_parent)

    get creatives_path(id: creative.id), headers: { "Turbo-Frame" => "creative-workspace-content" }

    assert_response :success
    assert_select "turbo-frame#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{creative.id}']"
    assert_select ".creative-workspace-shell", count: 0
    assert_select creative_tree_stream_selector, count: 0
  end

  test "workspace frame falls back to root without exposing an inaccessible creative" do
    inaccessible = Creative.create!(user: users(:two), description: "Private workspace creative")

    get creatives_path(id: inaccessible.id), headers: { "Turbo-Frame" => "creative-workspace-content" }

    assert_response :success
    assert_select "turbo-frame#creative-workspace-content [data-workspace-navigation-state]:not([data-creative-id])"
    assert_select "[data-workspace-navigation-state][data-creative-path='[]']"
    assert_not_includes response.body, inaccessible.description
  end

  test "title row emits markdown editor flag so cached rich rows reopen in Lexical" do
    rich = Creative.create!(
      user: users(:one), content_type_input: "markdown", markdown_editor: "rich", markdown_source: "# hi"
    )

    get creatives_path(id: rich.id)

    assert_response :success
    assert_match(/data-markdown-editor="rich"/, response.body)
  end

  test "unconvert moves creative tree into parent comment" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    grandchild = creatives(:unconvert_grandchild)
    expected_markdown = nil
    Current.set(user: users(:one)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ])
    end

    assert_difference -> { parent.comments.count }, 1 do
      assert_difference -> { parent.children.count }, -1 do
        post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }
      end
    end

    assert_response :created
    parent.reload
    comment = parent.comments.order(:created_at).last
    assert_equal expected_markdown, comment.content
    assert_raises(ActiveRecord::RecordNotFound) { creative.reload }
    assert_raises(ActiveRecord::RecordNotFound) { grandchild.reload }
  end

  test "unconvert without parent returns error" do
    creative = creatives(:root_parent)
    post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("collavre.creatives.index.unconvert_no_parent"), body["error"]
  end

  test "unconvert requires admin permission" do
    creative = creatives(:unconvert_target)
    parent = creative.parent
    sign_out
    sign_in_as(users(:two), password: "password")
    CreativeShare.create!(creative: parent, user: users(:two), permission: :feedback)

    assert_no_changes -> { creative.reload.children.count } do
      post unconvert_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal I18n.t("collavre.creatives.errors.no_permission"), body["error"]
  end

  test "export markdown requires read permission for parent creative" do
    creative = creatives(:root_parent)
    sign_out
    sign_in_as(users(:two), password: "password")

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :forbidden
  end

  test "export markdown returns markdown for readable parent creative" do
    creative = creatives(:root_parent)

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    assert_equal "text/markdown", response.media_type
    expected_markdown = nil
    Current.set(user: users(:one)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    end
    assert_equal expected_markdown, response.body
  end

  test "export markdown requires read permission on parent creative's effective origin" do
    creative = creatives(:unconvert_target)
    origin = creative.effective_origin
    sign_out
    sign_in_as(users(:two), password: "password")

    refute origin.has_permission?(users(:two), :read)

    get export_markdown_creatives_path(parent_id: creative.id), headers: { "ACCEPT" => "text/markdown" }

    assert_response :forbidden
  end

  test "export markdown includes only readable root creatives" do
    creative = creatives(:root_parent)
    sign_out
    sign_in_as(users(:two), password: "password")
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end

    get export_markdown_creatives_path, headers: { "ACCEPT" => "text/markdown" }

    assert_response :success
    expected_markdown = nil
    Current.set(user: users(:two)) do
      expected_markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative.effective_origin ])
    end
    assert_equal expected_markdown, response.body
  end

  # === HTTP Caching Tests ===

  test "show JSON ETag varies per user" do
    creative = creatives(:root_parent)

    # First user request
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_one_etag = response.headers["ETag"]

    # Second user request
    sign_out
    sign_in_as(users(:two), password: "password")
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_two_etag = response.headers["ETag"]

    assert_not_equal user_one_etag, user_two_etag, "ETag should vary per user"
  end

  test "show JSON ETag differs for anonymous vs authenticated" do
    creative = creatives(:root_parent)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: nil, permission: :read)
    end

    # Authenticated request
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    auth_etag = response.headers["ETag"]

    # Anonymous request
    sign_out
    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    anon_etag = response.headers["ETag"]

    assert_not_equal auth_etag, anon_etag, "ETag should differ between authenticated and anonymous users"
  end

  test "show JSON ETag changes when linked creative origin updates" do
    parent = creatives(:root_parent)
    child = creatives(:unconvert_target)
    # Create a linked creative pointing to child
    linked = Creative.create!(user: users(:one), parent: parent, origin: child)

    get creative_path(linked), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Update the origin creative
    child.touch

    get creative_path(linked), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]

    assert_not_equal original_etag, updated_etag, "ETag should change when linked creative's origin updates"
  end

  test "show JSON user-private prompt_for does not leak to other users" do
    creative = creatives(:root_parent)
    # Create a private prompt for user one (prompt_for looks for "> " prefix)
    creative.comments.create!(user: users(:one), content: "> secret instructions for user one", private: true)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_one_data = JSON.parse(response.body)
    user_one_prompt = user_one_data["prompt"]

    # User one should see their own prompt
    assert_equal "secret instructions for user one", user_one_prompt,
      "User should see their own private prompt"

    # Grant read access to user two
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end
    sign_out
    sign_in_as(users(:two), password: "password")

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    user_two_data = JSON.parse(response.body)
    user_two_prompt = user_two_data["prompt"]

    # User two should NOT see user one's private prompt
    assert_nil user_two_prompt, "Private prompt should not leak to other users"
  end

  test "show JSON ETag changes when prompt comment is added" do
    creative = creatives(:root_parent)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Add a prompt comment
    creative.comments.create!(user: users(:one), content: "> new prompt", private: true)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]

    assert_not_equal original_etag, updated_etag,
      "ETag should change when prompt comment is added"
  end

  test "show JSON ETag changes when child is added" do
    creative = creatives(:root_parent)

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    original_etag = response.headers["ETag"]

    # Add a child
    Creative.create!(user: users(:one), parent: creative, description: "New Child")

    get creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    updated_etag = response.headers["ETag"]
    updated_data = JSON.parse(response.body)

    assert_not_equal original_etag, updated_etag,
      "ETag should change when child is added"
    assert updated_data["has_children"], "has_children should be true after adding child"
  end

  test "children endpoint sets private no-store headers" do
    creative = creatives(:root_parent)

    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    cache_control = response.headers["Cache-Control"]
    # no-store is stronger than no-cache - it prevents all caching
    assert_includes cache_control, "private", "Children endpoint should set private to prevent proxy caching"
    assert_includes cache_control, "no-store", "Children endpoint should set no-store to prevent browser caching"
  end

  test "children endpoint returns new children in response" do
    creative = creatives(:root_parent)

    # First request
    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    first_data = JSON.parse(response.body)
    first_child_ids = first_data["creatives"].map { |c| c["id"] }

    # Add a new child
    new_child = Creative.create!(user: users(:one), parent: creative, description: "Brand New Child")

    # Second request - should see the new child
    get children_creative_path(creative), headers: { "ACCEPT" => "application/json" }
    assert_response :success
    second_data = JSON.parse(response.body)
    second_child_ids = second_data["creatives"].map { |c| c["id"] }

    assert_includes second_child_ids, new_child.id,
      "New child should appear in response"
    assert_not_includes first_child_ids, new_child.id,
      "New child should not have been in first response"
  end

  test "index paints a loading placeholder inside the tree, never the empty state" do
    get creatives_path(id: creatives(:childless_creative).id)

    assert_response :success
    # The tree is client-rendered, so the server cannot know yet whether it is
    # empty. Rendering the empty state here would flash "No sub-creatives yet" on
    # the first paint of every load, before Stimulus has even booted. The loading
    # placeholder is what belongs in the container; the empty state waits in the
    # <template> until the fetch actually reports zero rows.
    assert_select "#creatives > div[data-creatives-tree-loading]", count: 1 do
      assert_select "span.creative-loading-dot", count: 3
    end
    assert_select "#creatives div[data-creatives-empty-state]", count: 0
  end

  test "index labels the loading placeholder through i18n" do
    get creatives_path(id: creatives(:childless_creative).id)

    assert_response :success
    placeholder = css_select("#creatives > div[data-creatives-tree-loading]").first
    assert_equal I18n.t("collavre.creatives.index.loading_creatives"), placeholder["aria-label"]
    assert_equal "status", placeholder["role"]
    # tree_controller reuses the same string when it builds the indicator for
    # later reloads, so the accessible name does not switch languages mid-session.
    assert_equal I18n.t("collavre.creatives.index.loading_creatives"),
      css_select("#creatives").first["data-creatives--tree-loading-text-value"]
  end

  test "index renders an empty-state template outside the client-rendered tree" do
    # The tree is client-rendered and every load wipes #creatives, so the empty
    # state cannot be server-rendered into the container. The template is the copy
    # showEmptyState() / restoreTreeEmptyState() clone from once the tree is known
    # to be empty.
    get creatives_path(id: creatives(:root_parent).id)

    assert_response :success
    assert_select "template#creatives-empty-state-template", count: 1
    assert_select "#creatives template#creatives-empty-state-template", count: 0
    template = css_select("template#creatives-empty-state-template").first
    assert_includes template.to_html, "data-creatives-empty-state"
    # The plain "no sub-creatives" sentence was replaced by the empty-state card;
    # its heading is what the placeholder carries now.
    assert_includes template.to_html, I18n.t("collavre.creatives.index.empty_state_heading_sub")
  end

  test "index no longer passes empty-state markup as a controller value" do
    get creatives_path(id: creatives(:root_parent).id)

    assert_response :success
    assert_nil css_select("#creatives").first["data-creatives--tree-empty-html-value"]
  end

  test "index allows public access by default" do
    sign_out
    get creatives_path
    assert_response :success
  end

  test "index requires login when system setting enabled" do
    SystemSetting.create!(key: "creatives_login_required", value: "true")
    sign_out

    get creatives_path
    assert_redirected_to new_session_path
  end
end
