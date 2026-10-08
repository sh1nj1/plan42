require "test_helper"

module Collavre
  class SeoControllerTest < ActionDispatch::IntegrationTest
    setup do
      SystemSetting.where(key: "creatives_login_required").destroy_all
      @owner = users(:one)
    end

    def publish(description)
      creative = Creative.create!(user: @owner, description: description)
      perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
      creative.reload
    end

    def sitemap_locs
      Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").map(&:text)
    end

    test "robots allows public pages and points at the sitemap" do
      get "/robots.txt"

      assert_response :success
      assert_equal "text/plain", response.media_type
      assert_includes response.body, "Allow: /p/"
      assert_includes response.body, "Disallow: /\n"
      assert_equal [ "Allow: /p/", "Allow: /assets/", "Allow: /rails/active_storage/", "Allow: /public-assets/", "Allow: /creatives?format=json", "Allow: /creatives/*/children", "Allow: /sitemap.xml" ],
                   response.body.lines.grep(/^Allow:/).map(&:strip)
      assert_includes response.body, "Sitemap: http://www.example.com/sitemap.xml"
      assert_includes response.headers["Cache-Control"], "public"
    end

    test "robots disallows everything when creatives require login" do
      SystemSetting.create!(key: "creatives_login_required", value: "true")

      get "/robots.txt"

      assert_equal "User-agent: *\nDisallow: /\n", response.body
    end

    test "sitemap lists published creatives that are still public" do
      published = publish("<p>Published Plan</p>")
      revoked = publish("Revoked")
      perform_enqueued_jobs { CreativeShare.find_by!(creative: revoked, user_id: nil).destroy! }
      no_access = Creative.create!(user: @owner, description: "Denied")
      perform_enqueued_jobs { CreativeShare.create!(creative: no_access, user: nil, permission: :no_access) }
      archived = publish("Archived")
      archived.update!(archived_at: Time.current)
      Creative.create!(user: @owner, description: "Private")

      get "/sitemap.xml"

      assert_response :success
      assert_equal "application/xml", response.media_type
      assert_equal [ "http://www.example.com/p/#{published.public_id}/published-plan" ], sitemap_locs
      assert_empty Nokogiri::XML(response.body).remove_namespaces!.xpath("//lastmod")
    end

    test "sitemap URLs use request host and mount prefix without route defaults" do
      root = publish("Root")
      defaults = Collavre::Engine.routes.default_url_options.dup
      Collavre::Engine.routes.default_url_options.clear
      host! "public.example.org"
      get "/sitemap.xml", env: { "SCRIPT_NAME" => "/workspace" }
      assert_response :success
      assert_equal [ "http://public.example.org/workspace/p/#{root.public_id}/root" ], sitemap_locs
      SeoController.stub(:sitemap_page_size, 1) do
        publish("Second")
        get "/sitemap.xml", env: { "SCRIPT_NAME" => "/workspace" }
        index = Nokogiri::XML(response.body).remove_namespaces!
        assert_equal %w[1 2].map { |page| "http://public.example.org/workspace/sitemap.xml?page=#{page}" },
                     index.xpath("//sitemap/loc").map(&:text)
      end
    ensure
      Collavre::Engine.routes.default_url_options.replace(defaults)
    end

    test "sitemap excludes descendants and linked placements" do
      root = publish("Root")
      inherited = Creative.create!(user: @owner, parent: root, description: "Inherited")
      explicit = Creative.create!(user: @owner, parent: root, description: "Explicit")
      linked = Creative.create!(user: @owner, origin: root)
      perform_enqueued_jobs do
        CreativeShare.create!(creative: explicit, user: nil, permission: :read)
        CreativeShare.create!(creative: linked, user: nil, permission: :read)
      end

      get "/sitemap.xml"

      assert_equal [ "http://www.example.com/p/#{root.public_id}/root" ], sitemap_locs
      assert inherited.publicly_readable?
    end

    test "sitemap never writes missing legacy addresses" do
      root = publish("Legacy")
      Creative.where(id: root.id).update_all(public_id: nil)
      get "/sitemap.xml"
      assert_response :success
      assert_nil root.reload.public_id
      assert_empty sitemap_locs
    end

    test "origin root delegates robots to a subpath engine mount" do
      Rails.application.routes.draw do
        get "/robots.txt", to: redirect("/collavre/robots.txt", status: 302)
        mount Collavre::Engine => "/collavre", as: "collavre"
      end
      get "/robots.txt"
      assert_redirected_to "http://www.example.com/collavre/robots.txt"
      follow_redirect!
      assert_response :success
      assert_includes response.body, "Allow: /collavre/p/"
      assert_includes response.body, "Allow: /collavre/public-assets/"
      assert_includes response.body, "Allow: /collavre/creatives?format=json"
      assert_includes response.body, "Disallow: /\n"
      assert_includes response.body, "Sitemap: http://www.example.com/collavre/sitemap.xml"
    ensure
      Rails.application.reload_routes!
    end

    test "sitemap is empty when creatives require login" do
      publish("Published Plan")
      SystemSetting.create!(key: "creatives_login_required", value: "true")

      get "/sitemap.xml"

      assert_response :success
      assert_empty sitemap_locs
    end

    test "sitemap pages roots in id order" do
      first = publish("First")
      second = publish("Second")
      third = publish("Third")

      SeoController.stub(:sitemap_page_size, 2) do
        get "/sitemap.xml", params: { page: 2 }
      end

      assert_equal [ "http://www.example.com/p/#{third.public_id}/third" ], sitemap_locs
      assert first.id < second.id
    end

    test "sitemap lists a new public root before the permission cache is built" do
      creative = Creative.create!(user: @owner, description: "Fresh")
      CreativeShare.create!(creative: creative, user: nil, permission: :read)
      creative.reload
      # Simulate the authz job not having propagated the share yet.
      CreativeSharesCache.where(creative_id: creative.id).delete_all

      get "/sitemap.xml"

      assert_equal [ "http://www.example.com/p/#{creative.public_id}/fresh" ], sitemap_locs
    end

    test "non scalar sitemap pages return an empty sitemap" do
      publish("Public page")
      [ [ "1" ], { value: "1" } ].each do |page|
        get "/sitemap.xml", params: { page: page }
        assert_response :success
        assert_empty sitemap_locs
      end
    end

    test "out of range sitemap pages never reach SQL offset" do
      publish("Public page")
      [ "9223372036854775808", "9" * 100 ].each do |page|
        Creatives::PermissionFilter.stub(:new, ->(**) { flunk "Out of range pages must not load candidates" }) do
          get "/sitemap.xml", params: { page: page }
        end
        assert_response :success
        assert_empty sitemap_locs
      end
    end

    test "a large sitemap is split behind a sitemap index" do
      first = publish("First")
      second = publish("Second")
      third = publish("Third")

      SeoController.stub(:sitemap_page_size, 2) do
        get "/sitemap.xml"
        index = Nokogiri::XML(response.body).remove_namespaces!
        assert_equal %w[1 2].map { |page| "http://www.example.com/sitemap.xml?page=#{page}" },
                     index.xpath("//sitemap/loc").map(&:text)

        get "/sitemap.xml", params: { page: 2 }
        assert_equal [ "http://www.example.com/p/#{third.public_id}/third" ], sitemap_locs

        get "/sitemap.xml", params: { page: 9 }
        assert_empty sitemap_locs
      end

      assert first.public_id && second.public_id
    end
  end
end
