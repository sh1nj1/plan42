require "test_helper"

class Collavre::KollavyHandoffTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @creative = Collavre::Creative.inbox_for(@owner)
    @agent = Collavre::Kollavy.seed!
    @share = Collavre::CreativeShare.find_by!(creative: @creative, user: @agent)
    @task = Collavre::Task.create!(agent: @agent, creative: @creative, status: "running", name: "Queued request",
      trigger_event_payload: { "creative" => { "id" => @creative.id }, "comment" => { "content" => "Private request" } })
    @service = Collavre::AiAgentService.new(@task)
  end

  teardown { Collavre::Current.reset }

  [ :destroy, :deny, :read ].each do |change|
    test "#{change} before execution cancels before building any prompt despite a stale grant" do
      revoke_share(change)
      @service.stub(:build_messages, -> { flunk "Revoked context must not be assembled" }) do
        assert_raises(Collavre::CancelledError) { @service.call }
      end
      assert_equal "cancelled", @task.reload.status
      assert_nil @task.reply_comment
    end
  end

  test "revocation during prompt preparation cancels before provider handoff" do
    client = Object.new
    def client.handed_off? = false
    client.define_singleton_method(:chat) { |*| raise "Revoked context must not reach provider" }
    original_build = @service.method(:build_messages)
    @service.stub(:build_messages, -> { result = original_build.call; revoke_share(:destroy); result }) do
      Collavre::AiClient.stub(:new, client) do
        assert_raises(Collavre::CancelledError) { @service.call }
      end
    end
    assert_equal "cancelled", @task.reload.status
  end

  [ "approval_gate", "tool" ].each do |kind|
    test "#{kind} resume cannot respond after feedback is downgraded to read" do
      @task.update!(pending_tool_call: { "kind" => kind, "approved" => true,
        "result" => "Approved", "messages" => [ { "role" => "user", "content" => "Earlier request" } ] })
      revoke_share(:read)
      @service.stub(:build_messages, -> { flunk "Read-only approval resume must not assemble context" }) do
        assert_raises(Collavre::CancelledError) { @service.call }
      end
      assert_equal "cancelled", @task.reload.status
      assert_nil @task.reply_comment
    end
  end

  test "feedback downgrade during prompt preparation prevents reply creation" do
    comment = @creative.comments.create!(user: @owner, content: "Please respond", skip_dispatch: true)
    @task.update!(trigger_event_payload: { "creative" => { "id" => @creative.id },
      "comment" => { "id" => comment.id, "content" => comment.content } })
    @service = Collavre::AiAgentService.new(@task)
    original_build = @service.method(:build_messages)
    @service.stub(:build_messages, -> { result = original_build.call; revoke_share(:read); result }) do
      Collavre::AiAgent::ReplyPlaceholder.stub(:call, ->(**) { flunk "Read-only agent must not create a reply" }) do
        assert_raises(Collavre::CancelledError) { @service.call }
      end
    end
    assert_equal "cancelled", @task.reload.status
    assert_nil @task.reply_comment
  end

  test "feedback permission remains sufficient for ordinary conversation" do
    @share.update!(permission: :feedback)
    client = Object.new
    def client.handed_off? = true
    def client.last_handoff_failed? = false
    def client.chat(*)
      yield "Readable context received"
    end
    Collavre::AiClient.stub(:new, client) do
      assert_equal "Readable context received", @service.call
    end
    assert_equal "running", @task.reload.status
  end

  test "linked conversation reaches the provider with origin context but no placement ancestors" do
    placement = Collavre::Creative.create!(user: @owner, description: "Private placement ancestor")
    link = Collavre::Creative.create!(user: @owner, parent: placement, origin: @creative)
    @creative.update!(description: "Readable origin context")
    comment = link.comments.create!(user: @owner, content: "Hello from link", skip_dispatch: true)
    @task.update!(creative: link, trigger_event_payload: {
      "creative" => { "id" => link.id }, "comment" => { "id" => comment.id, "content" => comment.content }
    })
    client = Object.new
    captured = nil
    client.define_singleton_method(:chat) { |contents, **_, &block| captured = contents; block.call("Linked reply") }
    def client.handed_off? = true
    def client.last_handoff_failed? = false
    Collavre::AiClient.stub(:new, client) do
      assert_equal "Linked reply", Collavre::AiAgentService.new(@task).call
    end
    assert_includes captured.to_s, "Readable origin context"
    refute_includes captured.to_s, "Private placement ancestor"
    assert_equal @creative.id, @task.reload.reply_comment.creative_id
  end

  private

  def revoke_share(change)
    # Bypass callbacks to model the interval before the authz worker runs.
    if change == :destroy
      @share.delete
    else
      @share.update_columns(permission: Collavre::CreativeShare.permissions[change == :read ? :read : :no_access])
    end
    assert Collavre::CreativeSharesCache.where(creative: @creative, user: @agent)
      .where.not(permission: :no_access).exists?, "Keep the stale grant to exercise authoritative reads"
  end
end
