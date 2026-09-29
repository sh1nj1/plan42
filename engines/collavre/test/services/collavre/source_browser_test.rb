# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Collavre::SourceBrowserTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("source-browser")
    write("app/models/topic.rb", "class Topic\n  MAIN = \"Main\"\nend\n")
    write("app/assets/logo.png", "\x89PNG\x00\x01".b)
    write("app/.env.local", "SECRET=1\n")
    write("config/locales/en.yml", "en:\n  hello: Hello\n")
    write("config/routes.rb", "draw\n")
    write("config/master.key", "abc\n")
    write("config/deploy.yml", "servers: []\n")
    write("engines/core/app/services/x.rb", "# x\n")
    write("engines/core/lib/y.rb", "# y\n")
    write("engines/core/config/locales/ko.yml", "ko:\n  hello: 안녕\n")
    write("engines/core/db/seeds.rb", "# seeds\n")
    write("app/tmp/cache.rb", "# cache\n")
    write("storage/development.sqlite3", "db")
    write("docs/guide.md", "# Guide\n")
    File.symlink(File.join(@dir, "config/master.key"), File.join(@dir, "app/key_link.rb"))
    @browser = Collavre::SourceBrowser.new(root: @dir)
  end

  teardown { FileUtils.remove_entry(@dir) }

  def write(rel, content)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  test "defaults to the Rails root" do
    assert_equal Rails.root, Collavre::SourceBrowser.root
    assert_equal Pathname.new(File.realpath(Rails.root)), Collavre::SourceBrowser.new.root
  end

  test "lists only allowlisted roots" do
    paths = @browser.list[:entries].map { |e| e[:path] }

    assert_equal %w[app config/locales config/routes.rb engines/core/app engines/core/config/locales engines/core/lib].sort,
                 paths.sort
    assert_equal "file", @browser.list[:entries].find { |e| e[:path] == "config/routes.rb" }[:type]
  end

  test "engine route fragments support read list and search without exposing adjacent secrets" do
    path = "engines/core/config/routes/account_settings.rb"
    write(path, "get 'account_settings'\n")
    write("engines/core/config/credentials.yml", "ROUTE_SECRET\n")
    File.symlink(File.join(@dir, "engines/core/config/credentials.yml"),
                 File.join(@dir, "engines/core/config/routes/secret.rb"))

    assert_includes @browser.read(path)[:content], "account_settings"
    assert_equal [ path ], @browser.list("engines/core/config/routes")[:entries].pluck(:path)
    assert_equal [ path ], @browser.search("account_settings")[:matches].pluck(:path)
    assert_empty @browser.search("ROUTE_SECRET")[:matches]
    assert_raises(Collavre::SourceBrowser::AccessDenied) do
      @browser.read("engines/core/config/routes/secret.rb")
    end
  end

  test "lists a directory without denied entries" do
    result = @browser.list("app")
    names = result[:entries].map { |e| e[:path] }

    assert_equal "app", result[:path]
    assert_includes names, "app/models"
    refute_includes names, "app/.env.local"
    refute_includes names, "app/tmp"
    refute result[:truncated]
  end

  test "truncates long listings" do
    stub_const(:MAX_LIST_ENTRIES, 1) do
      assert @browser.list("app")[:truncated]
    end
  end

  test "rejects listing a file or a path outside the allowlist" do
    assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.list("config/routes.rb") }
    assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.list("engines/core/db") }
  end

  test "reads a file with line numbers and ranges" do
    result = @browser.read("app/models/topic.rb", start_line: 2, end_line: 2)

    assert_equal "app/models/topic.rb", result[:path]
    assert_equal 3, result[:total_lines]
    assert_equal "2:   MAIN = \"Main\"\n", result[:content]
    assert_equal "1: class Topic\n", @browser.read("/app/models/topic.rb", start_line: 0, end_line: 1)[:content]
  end

  test "caps lines read per call" do
    write("app/long.rb", "x\n" * 10)
    stub_const(:MAX_READ_LINES, 3) do
      result = @browser.read("app/long.rb")
      assert_equal [ 1, 3 ], [ result[:start_line], result[:end_line] ]
    end
  end

  test "refuses secrets, traversal, symlinks out of the allowlist and missing files alike" do
    [ "config/master.key", "config/deploy.yml", "app/.env.local", "app/tmp/cache.rb", "storage/development.sqlite3",
      "app/../config/master.key", "../etc/passwd", "app/key_link.rb", "app/missing.rb", "engines/core/db/seeds.rb" ].each do |path|
      error = assert_raises(Collavre::SourceBrowser::AccessDenied, path) { @browser.read(path) }
      assert_equal "Not found or not readable: #{path}", error.message
    end
  end

  test "refuses directories, oversized and binary files" do
    assert_match "Not a file", assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.read("app/models") }.message
    assert_match "Binary file", assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.read("app/assets/logo.png") }.message
    write("app/invalid.rb", "\xff\xfe".b)
    assert_match "Binary file", assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.read("app/invalid.rb") }.message
    stub_const(:MAX_FILE_BYTES, 5) do
      assert_match "too large", assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.read("app/models/topic.rb") }.message
    end
  end

  test "searches case-insensitively across allowed files only" do
    result = @browser.search("HELLO")
    paths = result[:matches].map { |m| m[:path] }

    assert_equal [ "config/locales/en.yml", "engines/core/config/locales/ko.yml" ].sort, paths.sort
    assert_equal 2, result[:matches].first[:line]
    refute result[:truncated]
    assert_empty @browser.search("SECRET")[:matches]
    assert_empty @browser.search("abc")[:matches], "symlinked secrets must not be searched"
  end

  test "searches within a path, including a single file" do
    assert_equal [ "app/models/topic.rb" ], @browser.search("main", path: "app")[:matches].map { |m| m[:path] }
    assert_equal 1, @browser.search("draw", path: "config/routes.rb")[:matches].size
  end

  test "stops at the result and file limits" do
    stub_const(:MAX_SEARCH_RESULTS, 1) do
      result = @browser.search("#")
      assert_equal 1, result[:matches].size
      assert result[:truncated]
    end
    write("app/many.rb", "hit\nhit\n")
    stub_const(:MAX_SEARCH_RESULTS, 1) do
      assert_equal 1, @browser.search("hit", path: "app/many.rb")[:matches].size
    end
    stub_const(:MAX_SEARCH_FILES, 0) do
      assert_empty @browser.search("#")[:matches]
    end
  end

  test "file scan limit reports incomplete searches even with no matches" do
    write("app/search/a.rb", "first hit\n")
    write("app/search/b.rb", "last hit\n")
    stub_const(:MAX_SEARCH_FILES, 1) do
      result = @browser.search("hit", path: "app/search")
      assert_equal [ "first hit" ], result[:matches].pluck(:text)
      assert result[:truncated]
      empty = @browser.search("absent", path: "app/search")
      assert_empty empty[:matches]
      assert empty[:truncated]
    end
    stub_const(:MAX_SEARCH_FILES, 3) do
      result = @browser.search("hit", path: "app/search")
      assert_equal 2, result[:matches].size
      refute result[:truncated]
    end
  end

  test "all documentation is excluded from reads listings searches and aliases" do
    %w[test.md send-fcm-test.rb operations/new-guide.md].each do |name|
      write("docs/#{name}", "PRIVATE_OPERATIONAL_VALUE\n")
    end
    File.symlink(File.join(@dir, "docs/send-fcm-test.rb"), File.join(@dir, "app/push.rb"))
    File.symlink(File.join(@dir, "docs"), File.join(@dir, "app/manuals"))

    %w[docs docs/test.md docs/send-fcm-test.rb docs/operations/new-guide.md
       docs/guide.md app/../docs/send-fcm-test.rb app/push.rb app/manuals/send-fcm-test.rb].each do |path|
      assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.read(path) }
      assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.search("PRIVATE", path: path) }
      assert_raises(Collavre::SourceBrowser::AccessDenied) { @browser.list(path) }
    end
    FileUtils.mkdir_p(File.join(@dir, "engines/alias"))
    File.symlink(File.join(@dir, "docs"), File.join(@dir, "engines/alias/lib"))
    @browser = Collavre::SourceBrowser.new(root: @dir)
    refute_includes @browser.list("app")[:entries].map { |entry| entry[:path] }, "app/push.rb"
    refute_includes @browser.list("app")[:entries].map { |entry| entry[:path] }, "app/manuals"
    refute_includes @browser.list[:entries].map { |entry| entry[:path] }, "docs"
    assert_empty @browser.search("PRIVATE_OPERATIONAL_VALUE")[:matches]
    assert_includes @browser.read("app/models/topic.rb")[:content], "class Topic"
  end

  private

  def stub_const(name, value)
    original = Collavre::SourceBrowser.const_get(name)
    Collavre::SourceBrowser.send(:remove_const, name)
    Collavre::SourceBrowser.const_set(name, value)
    yield
  ensure
    Collavre::SourceBrowser.send(:remove_const, name)
    Collavre::SourceBrowser.const_set(name, original)
  end
end
