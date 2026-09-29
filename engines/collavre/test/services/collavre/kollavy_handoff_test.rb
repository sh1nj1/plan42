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

  [ :destroy, :deny ].each do |change|
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

  test "read permission remains sufficient for ordinary conversation" do
    @share.update!(permission: :read)
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

  private

  def revoke_share(change)
    # Bypass callbacks to model the interval before the authz worker runs.
    if change == :destroy
      @share.delete
    else
      @share.update_columns(permission: Collavre::CreativeShare.permissions[:no_access])
    end
    assert Collavre::CreativeSharesCache.where(creative: @creative, user: @agent)
      .where.not(permission: :no_access).exists?, "Keep the stale grant to exercise authoritative reads"
  end
end
