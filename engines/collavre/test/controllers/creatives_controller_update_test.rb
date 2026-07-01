require "test_helper"

class CreativesControllerUpdateTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user, password: "password"

    # Structure:
    # A -> B2 (Linked)
    # B -> B1 (Origin)
    @a = Creative.create!(description: "A", user: @user)
    @b = Creative.create!(description: "B", user: @user)

    @b1_origin = Creative.create!(description: "B1 Origin", user: @user, progress: 0.0, parent: @b)
    @b2_linked = Creative.create!(description: "B2 Linked", user: @user, origin: @b1_origin, parent: @a)
  end

  test "should update linked creative origin without 422 error even if origin_id is in params" do
    # Simulate the request typically sent by a form or frontend
    # It often includes all attributes of the object, including origin_id
    patch creative_url(@b2_linked), params: {
      creative: {
        progress: 0.5,
        description: "Updated Description",
        origin_id: @b1_origin.id # The problematic param
      }
    }

    # Should redirect to the creative (success)
    # If 422, it renders :edit (or returns json error)
    if response.code == "422"
        puts response.body # For debugging
    end
    assert_response :redirect
    assert_redirected_to creative_url(@b2_linked)

    # Verify the update propagated to the origin
    assert_equal 0.5, @b1_origin.reload.progress
  end

  test "update_metadata posts drop trigger warning when enabling without write-permission AI agent" do
    creative = Creative.create!(description: "Documentation", user: @user, data: {})
    feedback_ai = users(:ai_bot)
    CreativeShare.create!(creative: creative, user: feedback_ai, permission: :feedback)

    assert_difference -> { creative.comments.count }, 1 do
      patch update_metadata_creative_url(creative), params: {
        data: {
          trigger: { on_child_enter: true }
        }.to_json
      }
    end

    assert_response :success
    comment = creative.comments.order(:id).last
    assert_nil comment.user_id
    assert_includes comment.content, "⚠️"
    assert_includes comment.content, creative.creative_snippet
    assert_equal "Drop Trigger", comment.topic.name
  end

  test "update_metadata preserves markdown_source and content_type against stale payload" do
    creative = Creative.create!(
      description: "<p>html</p>",
      user: @user,
      data: {
        "markdown_source" => "current source",
        "content_type" => "markdown",
        "editor" => "rich",
        "foo" => "bar"
      }
    )

    patch update_metadata_creative_url(creative), params: {
      data: {
        markdown_source: "stale source",
        content_type: "richtext",
        foo: "baz"
      }.to_json
    }

    assert_response :success
    creative.reload
    assert_equal "current source", creative.data["markdown_source"]
    assert_equal "markdown", creative.data["content_type"]
    # A metadata save that omits "editor" must not drop the rich authoring flag,
    # else the Lexical-authored creative would reopen in the advanced textarea.
    assert_equal "rich", creative.data["editor"]
    assert_equal "baz", creative.data["foo"]
  end

  test "update_metadata strips markdown reserved keys when current data has none" do
    creative = Creative.create!(description: "<p>html</p>", user: @user, data: { "foo" => "bar" })

    patch update_metadata_creative_url(creative), params: {
      data: { markdown_source: "injected", content_type: "markdown", editor: "rich", foo: "baz" }.to_json
    }

    assert_response :success
    creative.reload
    assert_not creative.data.key?("markdown_source")
    assert_not creative.data.key?("content_type")
    assert_not creative.data.key?("editor")
    assert_equal "baz", creative.data["foo"]
  end

  test "update_metadata rejects non-hash JSON arrays without clobbering markdown fields" do
    creative = Creative.create!(
      description: "<p>html</p>",
      user: @user,
      data: { "markdown_source" => "keep me", "content_type" => "markdown", "foo" => "bar" }
    )

    patch update_metadata_creative_url(creative), params: { data: "[]" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("collavre.creatives.errors.metadata_must_be_object"), body["error"]
    creative.reload
    assert_equal "keep me", creative.data["markdown_source"]
    assert_equal "markdown", creative.data["content_type"]
    assert_equal "bar", creative.data["foo"]
  end

  test "update_metadata rejects non-hash JSON scalars without clobbering markdown fields" do
    creative = Creative.create!(
      description: "<p>html</p>",
      user: @user,
      data: { "markdown_source" => "keep me", "content_type" => "markdown" }
    )

    patch update_metadata_creative_url(creative), params: { data: "\"just a string\"" }

    assert_response :unprocessable_entity
    creative.reload
    assert_equal "keep me", creative.data["markdown_source"]
    assert_equal "markdown", creative.data["content_type"]
  end

  test "update_metadata non-hash payload error is localized in Korean" do
    creative = Creative.create!(
      description: "<p>html</p>",
      user: @user,
      data: { "markdown_source" => "keep me", "content_type" => "markdown" }
    )

    patch update_metadata_creative_url(creative), params: { data: "[]" }, headers: { "Accept-Language" => "ko" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "메타데이터는 객체여야 합니다.", body["error"]
  end

  test "update JSON response exposes rewritten markdown_source for client sync" do
    png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjAAAAAgABc3UBGAAAAABJRU5ErkJggg=="
    md_src  = "Hello ![img](data:image/png;base64,#{png_b64}) world"

    creative = Creative.create!(description: "<p>placeholder</p>", user: @user)

    patch creative_url(creative), params: {
      creative: { description: "<p>ignored</p>", markdown_source: md_src, content_type_input: "markdown" }
    }, headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "markdown", json["content_type"]
    assert json["markdown_source"].is_a?(String), "markdown_source should be in update response"
    assert_not_includes json["markdown_source"], "data:image/png;base64,",
      "Server should return rewritten markdown_source with blob path, not the original data URI"
    assert_match %r{/rails/active_storage/blobs/}, json["markdown_source"]
  end

  test "create JSON response exposes rewritten markdown_source for client sync" do
    png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjAAAAAgABc3UBGAAAAABJRU5ErkJggg=="
    md_src  = "Hello ![img](data:image/png;base64,#{png_b64}) world"

    post creatives_url, params: {
      creative: {
        description: "<p>ignored</p>",
        markdown_source: md_src,
        content_type_input: "markdown"
      }
    }, headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["id"].present?, "create response must include id"
    assert_equal "markdown", json["content_type"]
    assert json["markdown_source"].is_a?(String), "create response should expose markdown_source"
    assert_not_includes json["markdown_source"], "data:image/png;base64,",
      "Server should return rewritten markdown_source with blob path, not the original data URI"
    assert_match %r{/rails/active_storage/blobs/}, json["markdown_source"]
  end

  test "update JSON response omits markdown_source for read-only parent_id-only PATCH" do
    owner = users(:one)
    reader = users(:two)

    origin = Creative.create!(
      description: "<p>secret html</p>",
      user: owner,
      data: { "content_type" => "markdown", "markdown_source" => "secret source" }
    )
    new_parent = Creative.create!(description: "New Parent", user: reader)
    old_parent = Creative.create!(description: "Old Parent", user: reader)
    linked = Creative.create!(description: "<p>link</p>", user: owner, origin: origin, parent: old_parent)
    CreativeShare.create!(creative: linked, user: reader, permission: :read)

    sign_in_as reader, password: "password"

    patch creative_url(linked), params: {
      creative: { parent_id: new_parent.id }
    }, headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert_not json.key?("markdown_source"),
      "read-only recipient must not receive origin markdown_source via parent-only PATCH"
    assert_equal new_parent.id, linked.reload.parent_id
  end

  test "update_metadata does not post duplicate warning when already enabled" do
    creative = Creative.create!(description: "Documentation", user: @user, data: { "trigger" => { "on_child_enter" => true } })
    feedback_ai = users(:ai_bot)
    CreativeShare.create!(creative: creative, user: feedback_ai, permission: :feedback)

    assert_no_difference -> { creative.comments.count } do
      patch update_metadata_creative_url(creative), params: {
        data: {
          trigger: { on_child_enter: true }
        }.to_json
      }
    end

    assert_response :success
  end

  test "update_metadata preserves registered reserved key when payload omits it" do
    # Register a dummy vendor-neutral key "x" to test the registry seam.
    # Reset after this test to avoid polluting other tests.
    Collavre::Creative.register_reserved_metadata_key("x")
    creative = Creative.create!(
      description: "<p>test</p>",
      user: @user,
      data: { "x" => "protected-value", "other" => "changeable" }
    )

    patch update_metadata_creative_url(creative), params: {
      data: { other: "new-value" }.to_json  # omits "x"
    }

    assert_response :success
    creative.reload
    assert_equal "protected-value", creative.data["x"], "Reserved key 'x' should be preserved when omitted from payload"
    assert_equal "new-value", creative.data["other"]
  ensure
    Collavre::Creative.instance_variable_set(:@registered_reserved_metadata_keys, nil)
  end
end
