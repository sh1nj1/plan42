require "test_helper"
require "rubygems/package"
require "tmpdir"

class AgentProvisioningArchiveTest < ActiveSupport::TestCase
  test "skill archive is deterministic and contains the Collavre skill" do
    first = Collavre::AgentProvisioning::Archive.collavre_skill
    second = Collavre::AgentProvisioning::Archive.send(
      :build_from_directory,
      Rails.root.join("skills/collavre")
    )

    assert_equal first, second
    entries = archive_entries(first)
    assert_includes entries.keys, "SKILL.md"
    assert_includes entries.keys, "scripts/collavre"
    assert_includes entries.fetch("SKILL.md"), "Manage Collavre Creatives"
  end

  test "engine gem packages the provisioning skill" do
    specification = Gem::Specification.load(Collavre::Engine.root.join("collavre.gemspec").to_s)

    assert_includes specification.files, "skills/collavre/SKILL.md"
    assert_includes specification.files, "skills/collavre/scripts/collavre"
    assert specification.files.all? { |path| Collavre::Engine.root.join(path).file? }
    assert_predicate Collavre::Engine.root.join("skills/collavre/SKILL.md"), :file?
  end

  test "rejects a missing or empty skill source" do
    assert_raises(ArgumentError) do
      Collavre::AgentProvisioning::Archive.send(:build_from_directory, Pathname("/missing/skill"))
    end

    Dir.mktmpdir do |directory|
      assert_raises(ArgumentError) do
        Collavre::AgentProvisioning::Archive.send(:build_from_directory, Pathname(directory))
      end
    end
  end

  test "workspace config contains the callback URL and token" do
    workspace = Struct.new(:config_payload).new({ url: "https://collavre.example", token: "callback-token" })
    def workspace.config_payload(base_url:)
      { url: base_url, token: "callback-token" }
    end

    bytes = Collavre::AgentProvisioning::Archive.workspace_config(workspace, base_url: "https://collavre.example")
    config = JSON.parse(archive_entries(bytes).fetch("config.json"))

    assert_equal "https://collavre.example", config.fetch("url")
    assert_equal "callback-token", config.fetch("token")
  end

  test "rejects binary and oversized expanded content" do
    assert_raises(ArgumentError) do
      Collavre::AgentProvisioning::Archive.send(
        :build,
        { "binary" => { content: "a\0b", mode: 0o644 } }
      )
    end

    oversized = "a" * (Collavre::AgentProvisioning::Archive::MAX_FILE_SIZE + 1)
    assert_raises(ArgumentError) do
      Collavre::AgentProvisioning::Archive.send(
        :build,
        { "large" => { content: oversized, mode: 0o644 } }
      )
    end
  end

  private

  def archive_entries(bytes)
    gzip = Zlib::GzipReader.new(StringIO.new(bytes))
    Gem::Package::TarReader.new(gzip).each_with_object({}) do |entry, result|
      result[entry.full_name] = entry.read if entry.file?
    end
  ensure
    gzip&.close
  end
end
