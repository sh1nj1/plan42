require_relative "../test_helper"

class NotionJobsTest < ActiveJob::TestCase
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @user = create_user
    @account = create_notion_account(@user)
    @creative = create_creative(@user)
    @link = @account.notion_page_links.create!(creative: @creative, page_id: "page", page_title: "Title", parent_page_id: "parent")
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "export delegates to the shared tree service" do
    service = Minitest::Mock.new
    service.expect(:sync_creative, @link, [ @creative ], parent_page_id: "parent")
    CollavreNotion::NotionService.stub(:new, service) do
      CollavreNotion::NotionExportJob.perform_now(@creative, @account, "parent")
    end
    assert service.verify
  end

  test "sync delegates with the exact requested link" do
    service = Minitest::Mock.new
    service.expect(:sync_creative, @link, [ @creative ], page_link: @link)
    CollavreNotion::NotionService.stub(:new, service) do
      CollavreNotion::NotionSyncJob.perform_now(@creative, @account, @link.page_id)
    end
    assert service.verify
  end

  test "stable link identity survives root replacement and rate limited retry" do
    link = @link
    calls = []
    service = Object.new
    service.define_singleton_method(:sync_creative) do |creative, page_link:|
      calls << page_link.page_id
      if calls.one?
        page_link.update!(page_id: "replacement")
        raise CollavreNotion::NotionRateLimitError
      end
    end
    CollavreNotion::NotionService.stub(:new, service) do
      perform_enqueued_jobs do
        CollavreNotion::NotionSyncJob.perform_later(@creative, @account, page_link_id: link.id)
      end
    end
    assert_equal [ "page", "replacement" ], calls
  end

  test "sync skips disconnected pages" do
    service = Minitest::Mock.new
    CollavreNotion::NotionService.stub(:new, service) do
      assert_nil CollavreNotion::NotionSyncJob.perform_now(@creative, @account, "missing")
    end
    assert service.verify
  end

  test "both jobs retry rate limits" do
    service = Object.new
    def service.sync_creative(*)
      raise CollavreNotion::NotionRateLimitError
    end
    CollavreNotion::NotionService.stub(:new, service) do
      [ CollavreNotion::NotionExportJob, CollavreNotion::NotionSyncJob ].each do |job|
        assert_enqueued_with(job: job) { job.perform_now(@creative, @account, "page") }
      end
    end
  end

  test "ambiguous connection failures are not automatically retried" do
    service = Object.new
    def service.sync_creative(*)
      raise CollavreNotion::NotionConnectionError
    end
    CollavreNotion::NotionService.stub(:new, service) do
      [ CollavreNotion::NotionExportJob, CollavreNotion::NotionSyncJob ].each do |job|
        assert_raises(CollavreNotion::NotionConnectionError) { job.perform_now(@creative, @account, "page") }
      end
    end
  end
  test "unexpected failures propagate from both jobs" do
    service = Object.new
    def service.sync_creative(*)
      raise ArgumentError, "unexpected"
    end
    CollavreNotion::NotionService.stub(:new, service) do
      [ CollavreNotion::NotionExportJob, CollavreNotion::NotionSyncJob ].each do |job|
        assert_raises(ArgumentError) { job.perform_now(@creative, @account, "page") }
      end
    end
  end
end
