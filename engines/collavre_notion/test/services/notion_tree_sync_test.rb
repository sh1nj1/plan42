require_relative "../test_helper"

class NotionTreeSyncTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :pages, :blocks, :deleted, :moves, :archived
    attr_accessor :fail_title, :fail_append, :fail_delete, :search_results

    def initialize
      @pages, @blocks, @deleted, @moves, @archived = {}, {}, [], [], []
      @sequence = 0
      @search_results = [ { "id" => "workspace" } ]
    end

    def search_pages(**)
      { "results" => search_results }
    end

    def create_page(parent_id:, title:, blocks: [])
      raise CollavreNotion::NotionRateLimitError if title == fail_title
      id = next_id
      @pages[id] = { parent: parent_id, title: title }
      { "id" => id, "url" => "https://notion.so/#{id}" }
    end

    def get_page(id)
      raise CollavreNotion::NotionNotFoundError unless @pages.key?(id)
      @pages.fetch(id).stringify_keys
    end

    def update_page(id, properties:, **)
      @pages.fetch(id)[:title] = properties.dig(:title, :title, 0, :text, :content)
    end

    def append_blocks(id, blocks)
      raise CollavreNotion::NotionRateLimitError if fail_append
      { "results" => blocks.map { |block| block_id = next_id; @blocks[block_id] = [ id, block ]; { "id" => block_id } } }
    end

    def delete_block(id)
      raise CollavreNotion::NotionRateLimitError if fail_delete
      @deleted << id
      @blocks.delete(id)
    end

    def move_page(id, parent_id:)
      @moves << [ id, parent_id ]
      @pages.fetch(id)[:parent] = parent_id
    end

    def archive_page(id)
      @archived << id
    end

    private

    def next_id
      @sequence += 1
      "notion-#{@sequence}"
    end
  end

  setup do
    @user = create_user
    @account = create_notion_account(@user)
    @root = create_creative(@user)
    @service = CollavreNotion::NotionService.new(user: @user)
    @client = FakeClient.new
    @service.instance_variable_set(:@client, @client)
    def @service.sleep(*) = nil
  end

  test "every creative including deep and empty leaves gets a page in sibling order" do
    first = child(@root, "first")
    second = child(@root, "second")
    deepest = 8.times.reduce(first) { |parent, n| child(parent, "level #{n}") }
    empty = child(deepest, "temporary")
    empty.update_column(:description, "")
    link = sync
    assert_equal 12, link.notion_page_nodes.count
    assert_equal 12, @client.pages.size
    assert_equal node(link, first).page_id, @client.pages.keys[1]
    assert_equal node(link, second).page_id, @client.pages.keys.last
    assert_equal node(link, deepest).page_id, @client.pages.fetch(node(link, empty).page_id)[:parent]
    assert_equal I18n.t("collavre_notion.modal.untitled"), @client.pages.fetch(node(link, empty).page_id)[:title]
    assert link.last_synced_at
  end

  test "missing active child is recreated with fresh content and retained descendants reparented" do
    a = child(@root, "A")
    b = child(a, "B")
    link = sync
    old = node(link, a)
    old_ids = old.body_block_ids
    @client.pages.delete(old.page_id)
    a.update!(description: "Changed A")
    sync
    replacement = node(link, a)
    assert_equal old.id, replacement.id
    assert_not_equal old.page_id, replacement.page_id
    assert_equal "Changed A", @client.pages[replacement.page_id][:title]
    assert_equal replacement.page_id, node(link, b).parent_page_id
    assert_empty old_ids & replacement.body_block_ids
    assert_empty old_ids & @client.deleted
    assert replacement.content_hash
    pages = @client.pages.deep_dup
    sync
    assert_equal pages, @client.pages
  end

  test "missing unchanged root and descendants recover through the original export link" do
    a = child(@root, "A")
    link = sync
    old_root = link.page_id
    @client.pages.clear
    @service.sync_creative(@root, page_link: link)
    assert_not_equal old_root, link.reload.page_id
    assert_equal node(link, @root).page_id, link.page_id
    assert_equal "https://notion.so/#{link.page_id}", link.page_url
    assert_equal "workspace", @client.pages[link.page_id][:parent]
    assert_equal link.page_id, node(link, a).parent_page_id
    assert_equal 2, @client.pages.size
    assert_equal link.id, sync.id
    assert_equal 2, @client.pages.size
  end

  test "archived and trashed active pages recover even without content changes" do
    link = sync
    [ "archived", "in_trash" ].each do |flag|
      old_id = link.reload.page_id
      @client.pages[old_id][flag] = true
      sync
      assert_not_equal old_id, link.reload.page_id
      assert node(link, @root).content_hash
    end
  end

  test "pages deleted during update or move recover once and sync under the intended parent" do
    a = child(@root, "A")
    b = child(@root, "B")
    link = sync
    [ :update_page, :move_page ].each do |operation|
      old_id = node(link, a).page_id
      a.update!(description: "Changed A") if operation == :update_page
      a.update!(parent: b) if operation == :move_page
      original = @client.method(operation)
      @client.stub(operation, ->(id, **args) {
        raise CollavreNotion::NotionNotFoundError if id == old_id
        original.call(id, **args)
      }) { sync }
      assert_not_equal old_id, node(link, a).page_id
      expected_parent = operation == :move_page ? node(link, b).page_id : link.page_id
      assert_equal expected_parent, node(link, a).parent_page_id
      assert node(link, a).content_hash
    end
  end

  test "failed replacement creation preserves mappings and later sync recovers" do
    link = sync
    old_id = link.page_id
    old_ids = node(link, @root).body_block_ids
    @client.pages.delete(old_id)
    @client.fail_title = CollavreNotion::NotionPageContent.title(@root)
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    assert_equal old_id, link.reload.page_id
    assert_equal old_id, node(link, @root).page_id
    assert_equal old_ids, node(link, @root).body_block_ids
    @client.fail_title = nil
    sync
    assert_not_equal old_id, link.reload.page_id
  end

  test "failed replacement content resumes on saved root and does not create duplicate pages" do
    link = sync
    last_synced_at = link.last_synced_at
    @client.pages.clear
    @client.fail_append = true
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    replacement = link.reload.page_id
    assert_equal replacement, node(link, @root).page_id
    assert_nil node(link, @root).content_hash
    assert_equal last_synced_at, link.last_synced_at
    @client.fail_append = false
    sync
    assert_equal replacement, link.reload.page_id
    assert_equal 1, @client.pages.size
    assert node(link, @root).content_hash
  end

  test "other retrieval errors preserve mappings and do not create replacement pages" do
    link = sync
    original = node(link, @root).attributes
    [ 400, 401, 403, 429, 500 ].each do |status|
      real_client = CollavreNotion::NotionClient.new(@account)
      request = stub_request(:get, %r{/v1/pages/#{link.page_id}$}).to_return(status: status, body: "{}")
      @client.stub(:get_page, ->(id) { real_client.get_page(id) }) do
        assert_raises(CollavreNotion::NotionError) { sync }
      end
      assert_requested request, times: status == 429 ? 6 : 1
      WebMock.reset_executed_requests!
      assert_equal original, node(link, @root).attributes
      assert_equal 1, @client.pages.size
      assert_equal link.last_synced_at, link.reload.last_synced_at
    end
  end

  test "real page retrieval 404 replaces only the selected export root" do
    child(@root, "Child")
    first = sync
    second = @service.sync_creative(@root, parent_page_id: "other")
    second_nodes = second.notion_page_nodes.map(&:attributes)
    old_id = first.page_id
    real_client = CollavreNotion::NotionClient.new(@account)
    request = stub_request(:get, %r{/v1/pages/#{old_id}$}).to_return(status: 404, body: "{}")
    original = @client.method(:get_page)
    @client.stub(:get_page, ->(id) { id == old_id ? real_client.get_page(id) : original.call(id) }) do
      sync
      sync
    end
    assert_requested request, times: 1
    assert_not_equal old_id, first.reload.page_id
    assert_equal second_nodes, second.notion_page_nodes.reload.map(&:attributes)
    assert_equal 2, @account.notion_page_links.count
  end

  test "repeated not found during replacement update terminates and preserves replacement for retry" do
    link = sync
    @root.update!(description: "Changed")
    @client.stub(:update_page, ->(*) { raise CollavreNotion::NotionNotFoundError }) do
      assert_raises(CollavreNotion::NotionNotFoundError) { sync }
    end
    assert_equal 2, @client.pages.size
    assert_equal node(link, @root).page_id, link.reload.page_id
    assert_nil node(link, @root).content_hash
    sync
    assert_equal 2, @client.pages.size
  end

  test "unchanged exports reuse pages and body blocks" do
    child(@root, "child")
    link = sync
    pages = @client.pages.deep_dup
    blocks = @client.blocks.deep_dup
    assert_equal link.id, sync.id
    assert_equal pages, @client.pages
    assert_equal blocks, @client.blocks
    assert_empty @client.deleted
  end

  test "content updates preserve child pages and user blocks" do
    nested = child(@root, "child")
    link = sync
    nested_id = node(link, nested).page_id
    @client.blocks["user-block"] = [ link.page_id, { type: "paragraph" } ]
    old_ids = node(link, @root).body_block_ids
    @root.update!(description: "Updated root")
    sync
    assert_equal "Updated root", @client.pages[link.page_id][:title]
    assert_equal old_ids, @client.deleted
    assert @client.blocks.key?("user-block")
    assert_equal nested_id, node(link, nested).page_id
  end

  test "missing owned blocks are cleared and changed content syncs without repeated deletion" do
    link = sync
    old_ids = node(link, @root).body_block_ids
    @root.update!(description: "Updated after remote deletion")
    real_client = CollavreNotion::NotionClient.new(@account)
    requests = old_ids.map do |id|
      stub_request(:delete, %r{/v1/blocks/#{id}$}).to_return(status: 404, body: "{}")
    end
    @client.stub(:delete_block, ->(id) { real_client.delete_block(id) }) do
      sync
      assert_empty old_ids & node(link, @root).body_block_ids
      assert node(link, @root).content_hash
      ids = node(link, @root).body_block_ids
      sync
      assert_equal ids, node(link, @root).body_block_ids
    end
    requests.each { |request| assert_requested request, times: 1 }
  end

  test "missing legacy blocks are removed from tracking without repeated deletion" do
    link = sync
    link.notion_block_links.create!(creative: @root, block_id: "missing")
    real_client = CollavreNotion::NotionClient.new(@account)
    request = stub_request(:delete, %r{/v1/blocks/missing$}).to_return(status: 404, body: "{}")
    @client.stub(:delete_block, ->(id) { real_client.delete_block(id) }) do
      sync
      assert_empty link.notion_block_links.reload
      assert link.reload.last_synced_at
      sync
    end
    assert_requested request, times: 1
  end

  test "other deletion errors preserve owned and legacy tracking for retry" do
    link = sync
    old_ids = node(link, @root).body_block_ids
    legacy = link.notion_block_links.create!(creative: @root, block_id: "legacy")
    @root.update!(description: "Changed")
    real_client = CollavreNotion::NotionClient.new(@account)
    [ 400, 401, 403, 500 ].each do |status|
      stub_request(:delete, %r{/v1/blocks/}).to_return(status: status, body: "{}")
      @client.stub(:delete_block, ->(id) { real_client.delete_block(id) }) do
        assert_raises(CollavreNotion::NotionError) { sync }
        assert_equal old_ids, node(link, @root).body_block_ids
        assert_nil node(link, @root).content_hash
        assert legacy.reload
      end
    end
    sync
    legacy = link.notion_block_links.create!(creative: @root, block_id: "legacy-again")
    @client.stub(:delete_block, ->(id) { real_client.delete_block(id) }) do
      assert_raises(CollavreNotion::NotionError) { sync }
      assert legacy.reload
    end
    sync
    assert_empty link.notion_block_links.reload
  end

  test "new descendants are added and moved descendants retain page IDs" do
    a = child(@root, "A")
    b = child(@root, "B")
    c = child(a, "C")
    link = sync
    original = node(link, c).page_id
    c.update!(parent: b)
    d = child(a, "D")
    sync
    assert_equal original, node(link, c).page_id
    assert_equal [ [ original, node(link, b).page_id ] ], @client.moves
    assert_equal node(link, a).page_id, node(link, d).parent_page_id
  end

  test "archived and moved-out creatives are removed only after successful sync" do
    a = child(@root, "A")
    b = child(a, "B")
    c = child(@root, "C")
    link = sync
    removed_ids = [ a, b, c ].map { |creative| node(link, creative).page_id }
    a.update_column(:archived_at, Time.current)
    c.update!(parent: nil)
    sync
    assert_equal removed_ids.sort, @client.archived.sort
    assert_equal [ @root.id ], link.notion_page_nodes.pluck(:creative_id)
  end

  test "hard-deleted creative mapping survives until remote cleanup" do
    a = child(@root, "A")
    link = sync
    page_id = node(link, a).page_id
    a.destroy!
    assert link.notion_page_nodes.exists?(page_id: page_id)
    sync
    assert_includes @client.archived, page_id
    assert_not link.notion_page_nodes.exists?(page_id: page_id)
  end

  test "missing removed pages clear tracking and allow subsequent syncs" do
    archived = child(@root, "Archived")
    moved = child(@root, "Moved")
    deleted = child(@root, "Deleted")
    link = sync
    page_ids = [ archived, moved, deleted ].map { |creative| node(link, creative).page_id }
    last_synced_at = link.last_synced_at
    archived.update_column(:archived_at, Time.current)
    moved.update!(parent: nil)
    deleted.destroy!
    real_client = CollavreNotion::NotionClient.new(@account)
    requests = page_ids.map do |id|
      stub_request(:patch, %r{/v1/pages/#{id}$}).with(body: { archived: true }.to_json)
        .to_return(status: 404, body: "{}")
    end

    @client.stub(:archive_page, ->(id) { real_client.archive_page(id) }) do
      travel 1.minute do
        sync
        assert_equal [ @root.id ], link.notion_page_nodes.pluck(:creative_id)
        assert_operator link.reload.last_synced_at, :>, last_synced_at
        sync
      end
    end
    requests.each { |request| assert_requested request, times: 1 }
  end

  test "other archive errors preserve removed page tracking and sync timestamp for retry" do
    removed = child(@root, "Removed")
    link = sync
    page_id = node(link, removed).page_id
    last_synced_at = link.last_synced_at
    removed.update!(parent: nil)
    real_client = CollavreNotion::NotionClient.new(@account)

    [ 400, 401, 403, 429, 500 ].each do |status|
      stub_request(:patch, %r{/v1/pages/#{page_id}$}).with(body: { archived: true }.to_json)
        .to_return(status: status, body: "{}")
      @client.stub(:archive_page, ->(id) { real_client.archive_page(id) }) do
        travel 1.minute do
          assert_raises(CollavreNotion::NotionError) { sync }
          assert link.notion_page_nodes.exists?(page_id: page_id)
          assert_equal last_synced_at, link.reload.last_synced_at
        end
      end
    end
    sync
    assert_not link.notion_page_nodes.exists?(page_id: page_id)
    assert_includes @client.archived, page_id
  end

  test "destinations have independent mappings and explicit sync targets" do
    a = child(@root, "A")
    first = sync
    second = @service.sync_creative(@root, parent_page_id: "other")
    assert_not_equal first.id, second.id
    assert_not_equal node(first, a).page_id, node(second, a).page_id
    @root.update!(description: "Second only")
    @service.sync_creative(@root, page_link: second)
    assert_equal "Second only", @client.pages[second.page_id][:title]
    assert_not_equal "Second only", @client.pages[first.page_id][:title]
  end

  test "partial failure keeps completed pages and retries without duplicating them" do
    first = child(@root, "first")
    second = child(@root, "second")
    @client.fail_title = "second"
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    link = @account.notion_page_links.sole
    original = node(link, first).page_id
    assert_nil link.last_synced_at
    assert_equal 2, @client.pages.size
    @client.fail_title = nil
    sync
    assert_equal original, node(link, first).page_id
    assert_equal 3, @client.pages.size
    assert node(link, second)
  end

  test "body failure retries on the already created page" do
    @client.fail_append = true
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    link = @account.notion_page_links.sole
    assert_nil node(link, @root).content_hash
    @client.fail_append = false
    sync
    assert_equal 1, @client.pages.size
    assert node(link, @root).content_hash
  end

  test "legacy blocks remain on failure then only tracked blocks are deleted" do
    link = sync
    child(@root, "new")
    legacy = link.notion_block_links.create!(creative: @root, block_id: "legacy")
    @client.blocks["user"] = [ link.page_id, {} ]
    @client.fail_title = "new"
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    assert legacy.reload
    @client.fail_title = nil
    @client.fail_delete = true
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    assert legacy.reload
    @client.fail_delete = false
    sync
    assert_empty link.notion_block_links.reload
    assert_includes @client.deleted, "legacy"
    assert @client.blocks.key?("user")
  end

  test "default parent search and empty workspace" do
    @client.search_results = []
    assert_raises(CollavreNotion::NotionError) { @service.sync_creative(@root) }
    @client.search_results = [ { "id" => "workspace" } ]
    link = @service.sync_creative(@root)
    assert_equal "workspace", link.parent_page_id
    assert_equal link.id, @service.sync_creative(@root).id
  end

  test "rejects an export link owned by another root or account" do
    link = sync
    other = create_creative(@user)
    assert_raises(CollavreNotion::NotionError) { @service.sync_creative(other, page_link: link) }
  end

  test "long descriptions are preserved in chunks within the API limit" do
    description = "가" * 4010
    @root.update!(description: description)
    link = sync
    content = @client.blocks.values.map { |_, block| block.dig(:paragraph, :rich_text, 0, :text, :content) }
    assert_equal description, content.join
    assert content.all? { |part| part.length <= 2000 }
    assert_operator @client.pages[link.page_id][:title].length, :<=, 2000
  end

  test "legacy root page is reused when no page nodes exist yet" do
    nested = child(@root, "Nested")
    @client.pages["legacy-root"] = { parent: "workspace", title: "Old title" }
    link = @account.notion_page_links.create!(creative: @root, page_id: "legacy-root", page_title: "Old title", parent_page_id: "workspace")
    link.notion_block_links.create!(creative: nested, block_id: "old-heading")
    sync
    assert_equal "legacy-root", node(link, @root).page_id
    assert_equal 2, @client.pages.size
    assert_equal "legacy-root", node(link, nested).parent_page_id
    assert_equal [ "old-heading" ], @client.deleted
  end

  test "retained descendants move out before a removed parent is archived" do
    a = child(@root, "A")
    b = child(a, "B")
    link = sync
    old_parent = node(link, a).page_id
    b_id = node(link, b).page_id
    b.update!(parent: @root)
    a.update_column(:archived_at, Time.current)
    sync
    assert_equal [ [ b_id, link.page_id ] ], @client.moves
    assert_equal [ old_parent ], @client.archived
  end

  test "failure after a body batch does not duplicate blocks on retry" do
    calls = 0
    @client.define_singleton_method(:append_blocks) do |*args|
      calls += 1
      raise CollavreNotion::NotionRateLimitError if calls > 1
      super(*args)
    end
    @root.stub(:effective_description, "x" * 202000) do
      assert_raises(CollavreNotion::NotionRateLimitError) { sync }
      link = @account.notion_page_links.sole
      assert_equal 100, node(link, @root).body_block_ids.size
      assert_nil node(link, @root).content_hash
      @client.singleton_class.remove_method(:append_blocks)
      sync
      assert_equal 101, @client.blocks.size
      assert_equal 101, node(link, @root).body_block_ids.size
      assert_equal 1, @client.pages.size
    end
  end

  test "byte limited appends track split blocks and recover after partial failure" do
    calls = 0
    @client.define_singleton_method(:append_blocks) do |id, blocks|
      raise "Oversized request" if { children: blocks }.to_json.bytesize > 500_000
      calls += 1
      raise CollavreNotion::NotionError if calls == 2
      super(id, blocks)
    end
    value = "😀" * 200_000
    @root.stub(:effective_description, "<table><tr><td>#{value}</td></tr></table>") do
      assert_raises(CollavreNotion::NotionError) { sync }
      link = @account.notion_page_links.sole
      saved_ids = node(link, @root).body_block_ids
      assert_equal 1, saved_ids.size
      assert_nil node(link, @root).content_hash
      sync
      assert_equal saved_ids, @client.deleted
      assert_equal @client.blocks.keys, node(link, @root).body_block_ids
      assert node(link, @root).content_hash
      rows = @client.blocks.values.flat_map { |_, block| block.dig(:table, :children) }
      assert_equal value, rows.flat_map { |row| row.dig(:table_row, :cells, 0) }.map { |text| text.dig(:text, :content) }.join
      before = calls
      sync
      assert_equal before, calls
    end
  end

  test "large tables are appended separately in order between paragraph batches" do
    batches = []
    @client.define_singleton_method(:append_blocks) do |id, blocks|
      batches << blocks
      super(id, blocks)
    end
    rows = 1000.times.map { |index| "<tr><td>Row #{index}</td></tr>" }.join
    html = "<p>Before</p><table>#{rows}</table><p>After</p>"
    @root.stub(:effective_description, html) do
      link = sync
      assert_equal [ 1 ] * 12, batches.map(&:size)
      tables = batches.flatten.select { |block| block[:type] == "table" }
      assert_equal [ 100 ] * 10, tables.map { |block| block.dig(:table, :children).size }
      contents = tables.flat_map { |block| block.dig(:table, :children) }.map do |row|
        row.dig(:table_row, :cells, 0, 0, :text, :content)
      end
      assert_equal 1000.times.map { |index| "Row #{index}" }, contents
      assert_equal "Before", batches.first.first.dig(:paragraph, :rich_text, 0, :text, :content)
      assert_equal "After", batches.last.first.dig(:paragraph, :rich_text, 0, :text, :content)
      assert_equal @client.blocks.keys, node(link, @root).body_block_ids
      assert node(link, @root).content_hash
    end
  end

  test "reverting source content after a failed update restores the original body" do
    link = sync
    original = @root.description
    @root.update!(description: "Changed")
    @client.fail_append = true
    assert_raises(CollavreNotion::NotionRateLimitError) { sync }
    @root.update!(description: original)
    @client.fail_append = false
    sync
    assert_equal 1, node(link, @root).body_block_ids.size
    assert_equal original, @client.blocks.values.first.last.dig(:paragraph, :rich_text, 0, :text, :content)
  end

  test "an incomplete append response is not marked synced" do
    @client.define_singleton_method(:append_blocks) { |*| { "results" => [] } }
    assert_raises(CollavreNotion::NotionError) { sync }
    link = @account.notion_page_links.sole
    assert_nil link.last_synced_at
    assert_nil node(link, @root).content_hash
  end

  test "disconnecting deletes page mappings without modifying Notion" do
    child(@root, "Nested")
    link = sync
    assert_difference("CollavreNotion::NotionPageNode.count", -2) { link.destroy! }
    assert_equal 2, @client.pages.size
    assert_empty @client.archived
  end

  private

  def sync
    @service.sync_creative(@root, parent_page_id: "workspace")
  end

  def child(parent, description)
    Collavre::Creative.create!(user: @user, parent: parent, description: description)
  end

  def node(link, creative)
    link.notion_page_nodes.find_by!(creative_id: creative.id)
  end
end
