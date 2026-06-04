require "test_helper"

# Covers the lightweight "simple" JSON payload used by the creative picker popup:
# browsable mini-tree (has_children) and flat search results with breadcrumbs.
class CreativesPickerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")

    @token = "zqpicker"
    # root -> mid -> leaf (leaf matches the search token)
    @root = Creative.create!(user: @user, description: "Picker Root", sequence: 900)
    @mid = Creative.create!(user: @user, parent: @root, description: "Picker Mid", sequence: 1)
    @leaf = Creative.create!(user: @user, parent: @mid, description: "Picker Leaf #{@token}", sequence: 1)
    @root.reload
  end

  test "simple browse of roots reports has_children" do
    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body

    root_row = body.find { |c| c["id"] == @root.id }
    assert_not_nil root_row, "root creative should be present"
    assert_equal true, root_row["has_children"]
    assert root_row.key?("progress")
  end

  test "simple browse of children returns next level with has_children" do
    get collavre.creatives_path(format: :json, simple: true, id: @root.id)

    assert_response :success
    body = JSON.parse(response.body)
    mid_row = body.find { |c| c["id"] == @mid.id }
    assert_not_nil mid_row
    assert_equal true, mid_row["has_children"]

    # Leaf has no children
    get collavre.creatives_path(format: :json, simple: true, id: @mid.id)
    body = JSON.parse(response.body)
    leaf_row = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil leaf_row
    assert_equal false, leaf_row["has_children"]
  end

  test "simple browse reports has_children for a linked-creative shell via its origin" do
    # Origin owned by another user, shared (read) to the signed-in user, with a
    # readable child stored under the origin.
    origin = Creative.create!(user: users(:two), description: "Shared Origin", sequence: 950)
    Creative.create!(user: users(:two), parent: origin, description: "Shared Child", sequence: 1)
    CreativeShare.create!(creative: origin, user: @user, permission: :read) # propagates cache to subtree

    # Linked shell owned by the signed-in user appears as a root for them.
    shell = Creative.create!(user: @user, origin_id: origin.id, parent_id: nil)

    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    shell_row = body.find { |c| c["id"] == shell.id }
    assert_not_nil shell_row, "linked shell should appear as a root"
    # Children live under the origin (parent_id == origin.id), not the shell.
    # has_children must follow the effective origin to match what expansion shows.
    assert_equal true, shell_row["has_children"]
    # The effective origin id is exposed so the client can map search
    # breadcrumbs (origin ids) back to this shell node.
    assert_equal origin.id, shell_row["origin_id"]
  end

  test "simple browse omits origin_id for non-linked creatives" do
    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    root_row = body.find { |c| c["id"] == @root.id }
    assert_not_nil root_row
    assert_not root_row.key?("origin_id"), "non-linked creative should not carry origin_id"
  end

  test "simple browse does not report has_children when the only child is archived" do
    parent = Creative.create!(user: @user, description: "Has only archived child", sequence: 960)
    Creative.create!(user: @user, parent: parent, description: "Archived", sequence: 1,
                     archived_at: Time.current)

    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    row = body.find { |c| c["id"] == parent.id }
    assert_not_nil row
    # Expansion drops archived children (show_archived unset), so the toggle must
    # not be advertised — otherwise it opens to an empty branch.
    assert_equal false, row["has_children"]
  end

  test "simple browse does not report has_children for unreadable children" do
    parent = Creative.create!(user: @user, description: "Has unreadable child", sequence: 970)
    # Child owned by another user with no share to @user -> not readable.
    Creative.create!(user: users(:two), parent: parent, description: "Hidden", sequence: 1)

    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    row = body.find { |c| c["id"] == parent.id }
    assert_not_nil row
    # Advertising a toggle here would leak that hidden children exist.
    assert_equal false, row["has_children"]
  end

  test "simple search annotates results with ancestor breadcrumb path" do
    get collavre.creatives_path(format: :json, simple: true, search: @token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil match, "matched leaf should be returned"

    path = match["path"]
    assert_kind_of Array, path
    # Ordered root -> immediate parent, self excluded
    assert_equal [ @root.id, @mid.id ], path.map { |p| p["id"] }
    assert_equal "Picker Root", path.first["description"]
  end

  test "simple search supplies a reveal_path for a hit under a nested linked shell" do
    token = "zqreveal"
    # Origin subtree owned by another user, shared (read) to the signed-in user.
    origin = Creative.create!(user: users(:two), description: "Reveal Origin", sequence: 980)
    child = Creative.create!(user: users(:two), parent: origin, description: "Reveal Child #{token}", sequence: 1)
    CreativeShare.create!(creative: origin, user: @user, permission: :read) # propagates cache to subtree

    # The signed-in user's own folder, with the linked shell nested *under* it
    # (not a root) — so the origin-space breadcrumb alone can't reach the shell.
    folder = Creative.create!(user: @user, description: "Local Folder", sequence: 985)
    shell = Creative.create!(user: @user, origin_id: origin.id, parent: folder)

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == child.id }
    assert_not_nil match, "shared child should surface in search"
    # Keyed by the origin ancestor (origin) -> expand local folder, then the
    # shell, before walking the origin chain.
    assert_equal({ origin.id.to_s => [ folder.id, shell.id ] }, match["reveal_path"])
  end

  test "simple search omits reveal_path when the linked shell is archived" do
    token = "zqarchshell"
    origin = Creative.create!(user: users(:two), description: "Arch Origin", sequence: 990)
    child = Creative.create!(user: users(:two), parent: origin, description: "Arch Child #{token}", sequence: 1)
    CreativeShare.create!(creative: origin, user: @user, permission: :read)

    folder = Creative.create!(user: @user, description: "Arch Local Folder", sequence: 995)
    # Shell archived -> browse hides it, so a reveal_path targeting it would dead-end.
    Creative.create!(user: @user, origin_id: origin.id, parent: folder, archived_at: Time.current)

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == child.id }
    assert_not_nil match, "shared child still surfaces in search"
    assert_not match.key?("reveal_path"), "no reveal_path to an unrenderable archived shell"
  end

  test "simple search picks a renderable shell when several exist for one origin" do
    token = "zqmultishell"
    origin = Creative.create!(user: users(:two), description: "Multi Origin", sequence: 996)
    child = Creative.create!(user: users(:two), parent: origin, description: "Multi Child #{token}", sequence: 1)
    CreativeShare.create!(creative: origin, user: @user, permission: :read)

    # Two shells for the SAME origin: one behind an archived (unrendered) folder,
    # one under a visible folder. The reveal path must use the reachable shell.
    archived_folder = Creative.create!(user: @user, description: "Archived Folder", sequence: 997,
                                       archived_at: Time.current)
    Creative.create!(user: @user, origin_id: origin.id, parent: archived_folder)
    visible_folder = Creative.create!(user: @user, description: "Visible Folder", sequence: 998)
    visible_shell = Creative.create!(user: @user, origin_id: origin.id, parent: visible_folder)

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == child.id }
    assert_not_nil match
    assert_equal({ origin.id.to_s => [ visible_folder.id, visible_shell.id ] }, match["reveal_path"])
  end

  test "simple search maps each origin ancestor to its own shell at multiple depths" do
    token = "zqmultidepth"
    # Shared subtree: ancestor -> descendant; the hit is under the descendant.
    ancestor = Creative.create!(user: users(:two), description: "Depth Ancestor", sequence: 1000)
    descendant = Creative.create!(user: users(:two), parent: ancestor, description: "Depth Descendant", sequence: 1)
    child = Creative.create!(user: users(:two), parent: descendant, description: "Depth Child #{token}", sequence: 1)
    CreativeShare.create!(creative: ancestor, user: @user, permission: :read)

    # The user holds a shell for BOTH the ancestor and the descendant, each in a
    # different local folder. A single deepest path could not serve an ancestor
    # crumb click, so each origin must map to its own shell's local path.
    folder_a = Creative.create!(user: @user, description: "Folder A", sequence: 1001)
    shell_a = Creative.create!(user: @user, origin_id: ancestor.id, parent: folder_a)
    folder_d = Creative.create!(user: @user, description: "Folder D", sequence: 1002)
    shell_d = Creative.create!(user: @user, origin_id: descendant.id, parent: folder_d)

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == child.id }
    assert_not_nil match
    assert_equal(
      {
        ancestor.id.to_s => [ folder_a.id, shell_a.id ],
        descendant.id.to_s => [ folder_d.id, shell_d.id ]
      },
      match["reveal_path"]
    )
  end

  test "simple search omits reveal_path for hits in the user's own tree" do
    get collavre.creatives_path(format: :json, simple: true, search: @token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil match
    assert_not match.key?("reveal_path"), "own-tree hits need no reveal_path"
  end

  test "simple search excludes matches the user cannot read" do
    token = "zqsecret"
    mine = Creative.create!(user: @user, parent: @root, description: "Mine #{token}", sequence: 50)
    # Same token, owned by another user with no share -> must not surface.
    Creative.create!(user: users(:two), description: "Theirs #{token}", sequence: 51)

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    ids = body.map { |c| c["id"] }
    assert_includes ids, mine.id
    assert_equal 1, body.length, "only the readable match should be returned"
  end

  test "simple search results are capped at SIMPLE_SEARCH_LIMIT" do
    limit = ::Collavre::Creatives::IndexQuery::SIMPLE_SEARCH_LIMIT
    capped_token = "zqcap"
    (limit + 5).times do |i|
      Creative.create!(user: @user, parent: @root, description: "Cap #{capped_token} #{i}", sequence: 100 + i)
    end

    get collavre.creatives_path(format: :json, simple: true, search: capped_token)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal limit, body.length
  end

  test "simple search fills the cap with readable rows past a shorter unreadable match" do
    limit = ::Collavre::Creatives::IndexQuery::SIMPLE_SEARCH_LIMIT
    token = "zqrankcap"
    # Shortest description, ranks first, but unreadable: must not take a cap slot
    # nor block readable rows behind it.
    unreadable = Creative.create!(user: users(:two), description: token, sequence: 40)
    limit.times do |i|
      Creative.create!(user: @user, parent: @root, description: "#{token} mine #{i}", sequence: 100 + i)
    end

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    ids = body.map { |c| c["id"] }
    assert_equal limit, body.length, "the cap fills with readable rows, not the shorter unreadable one"
    assert_not_includes ids, unreadable.id
  end

  test "simple search windows in SQL without plucking the full match set" do
    token = "zqwindowed"
    3.times { |i| Creative.create!(user: @user, parent: @root, description: "#{token} #{i}", sequence: 300 + i) }

    statements = []
    callback = ->(_n, _s, _f, _id, payload) {
      next if payload[:name] == "SCHEMA"
      statements << payload[:sql]
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get collavre.creatives_path(format: :json, simple: true, search: token)
    end
    assert_response :success

    # The ranked window keeps the search as a subquery and caps with LIMIT, so the
    # match set never crosses into Ruby as a plucked id list.
    windowed = statements.any? do |sql|
      sql =~ /IN \(SELECT DISTINCT.+LEFT OUTER JOIN.+comments.+\).+ORDER BY LENGTH.+LIMIT/im
    end
    assert windowed, "expected a windowed subquery (IN (SELECT DISTINCT ... comments ...) ... LIMIT), got:\n#{statements.join("\n")}"

    # The eliminated path plucked every match first: a standalone DISTINCT id pluck
    # over the joined comments scope. It must not run for a search-only query.
    full_pluck = statements.any? do |sql|
      sql =~ /\ASELECT DISTINCT ["`]?creatives["`]?\.["`]?id["`]? FROM ["`]?creatives["`]? LEFT OUTER JOIN/i
    end
    assert_not full_pluck, "search-only path must not pluck the whole match set up front"
  end

  test "simple search scans past multiple windows of unreadable matches to fill the cap" do
    # Regression: the windowed scan must not stop at a fixed window ceiling. In a
    # multi-user install the match scope is every origin_id: nil row before permission
    # filtering, so a user's readable matches can sort after many unreadable ones.
    # Shrink the batch so a handful of rows already spans several windows, then place
    # the readable match past more than one window of shorter-ranked unreadable rows.
    token = "zqdeep"
    klass = ::Collavre::Creatives::IndexQuery
    original_batch = klass::PERMISSION_FILTER_BATCH
    klass.send(:remove_const, :PERMISSION_FILTER_BATCH)
    klass.const_set(:PERMISSION_FILTER_BATCH, 2)
    begin
      # Six unreadable rows (owned by another user, no share), shortest description so
      # they rank first — three full windows' worth.
      6.times do |i|
        Creative.create!(user: users(:two), description: token, sequence: 700 + i)
      end
      # The only readable match has a longer description, so it ranks last (past the
      # unreadable run). A capped scan would never reach it.
      mine = Creative.create!(user: @user, parent: @root, description: "#{token} readable tail", sequence: 800)

      get collavre.creatives_path(format: :json, simple: true, search: token)
    ensure
      klass.send(:remove_const, :PERMISSION_FILTER_BATCH)
      klass.const_set(:PERMISSION_FILTER_BATCH, original_batch)
    end

    assert_response :success
    body = JSON.parse(response.body)
    ids = body.map { |c| c["id"] }
    assert_includes ids, mine.id, "readable match past several windows must still be returned"
    assert_equal 1, body.length, "only the readable match should surface"
  end

  test "browse with multiple linked shells preloads origins instead of a per-shell query" do
    # Several shells at root, each pointing at a distinct shared origin. The
    # serialize path resolves effective_origin per shell twice (children_presence_set
    # + the row map); without the preload each resolution is a single-id origin load.
    shells = Array.new(3) do |i|
      origin = Creative.create!(user: users(:two), description: "Shared Origin #{i}", sequence: 960 + i)
      Creative.create!(user: users(:two), parent: origin, description: "Shared Child #{i}", sequence: 1)
      CreativeShare.create!(creative: origin, user: @user, permission: :read)
      Creative.create!(user: @user, origin_id: origin.id, parent_id: nil)
    end

    controller = Collavre::CreativesController.new
    controller.define_singleton_method(:params) { ActionController::Parameters.new(simple: "true") }
    collection = Creative.where(id: shells.map(&:id)).to_a

    single_id_loads = []
    callback = ->(_n, _s, _f, _id, payload) {
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA"
      # belongs_to :origin loads one row by primary key; the preload uses IN(...).
      single_id_loads << sql if sql =~ /FROM\s+["`]?creatives["`]?.*WHERE.*["`]?creatives["`]?\.["`]?id["`]?\s*=\s/i
    }

    Current.set(user: @user) do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        controller.send(:serialize_creatives, collection)
      end
    end

    assert_equal 0, single_id_loads.size,
      "expected origins preloaded (no per-shell load), got:\n#{single_id_loads.join("\n")}"
  end

  test "simple search masks a crumb whose path crosses an archived ancestor" do
    # Reachable state: archive the whole tree, then unarchive @mid — unarchive only
    # touches self_and_descendants, so @root stays archived while @mid/@leaf go
    # active. The leaf still surfaces (search filters the matched row only), but a
    # jump to @mid would expand from @root, which browse never renders -> dead-end.
    # So @mid must be masked too, not just the archived @root.
    @root.archive!
    @mid.reload.unarchive!

    get collavre.creatives_path(format: :json, simple: true, search: @token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil match, "the active leaf still surfaces despite the archived ancestor"

    path = match["path"]
    assert_equal [ @root.id, @mid.id ], path.map { |p| p["id"] }, "depth is preserved"
    assert path.all? { |p| p["restricted"] },
      "both the archived root and the crumb stranded behind it are masked"
  end

  test "simple search keeps a crumb navigable past an archived ancestor when a shell re-roots it" do
    token = "zqbypass"
    # Shared subtree root -> descendant -> hit, all owned by another user.
    rooto = Creative.create!(user: users(:two), description: "Bypass Root", sequence: 1010)
    desc  = Creative.create!(user: users(:two), parent: rooto, description: "Bypass Desc", sequence: 1)
    hit   = Creative.create!(user: users(:two), parent: desc, description: "Bypass Hit #{token}", sequence: 1)
    CreativeShare.create!(creative: rooto, user: @user, permission: :read)

    # The user holds a shell for the descendant, re-rooting navigation there.
    folder = Creative.create!(user: @user, description: "Bypass Folder", sequence: 1011)
    shell  = Creative.create!(user: @user, origin_id: desc.id, parent: folder)

    # Archive the shared tree, then unarchive the descendant: root stays archived,
    # descendant (and its shell) active -> the descendant crumb is reachable via
    # the shell even though the origin above it is archived.
    rooto.archive!
    desc.reload.unarchive!

    get collavre.creatives_path(format: :json, simple: true, search: token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == hit.id }
    assert_not_nil match
    path = match["path"]
    root_crumb = path.find { |p| p["id"] == rooto.id }
    desc_crumb = path.find { |p| p["id"] == desc.id }
    assert root_crumb["restricted"], "the archived shared root is masked"
    assert_not desc_crumb["restricted"],
      "the descendant stays navigable through its own shell, not masked by the archived root"
  end
end
