require "test_helper"

class Creatives::GithubIntegrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @github_account = GithubAccount.create!(
      user: @user,
      github_uid: "123",
      login: "sample-user",
      name: "Sample User",
      token: "sample-token"
    )
    GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @github_account,
      repository_full_name: "sample-user/example",
      webhook_secret: "existing-secret"
    )
    @creative.update!(github_gemini_prompt: 'Custom prompt: #{pr_title}')
    sign_in_as(@user, password: "password")
  end

  test "show returns webhook details for linked repositories" do
    get creative_github_integration_path(@creative), as: :json

    assert_response :success
    body = JSON.parse(response.body)

    assert body["connected"], "Expected response to indicate connected account"
    details = body.fetch("webhooks")
    assert details.key?("sample-user/example"), "Expected webhook details for repository"

    repo_details = details["sample-user/example"]
    assert_equal "existing-secret", repo_details["secret"]
    assert repo_details["url"].end_with?("/github/webhook")
    assert_equal 'Custom prompt: #{pr_title}', body["github_gemini_prompt"]
  end

  test "update stores webhook secrets for selected repositories" do
    payload = {
      repositories: [ "sample-user/example", "sample-user/another" ],
      github_gemini_prompt: 'Updated prompt: #{pr_title} #{diff}'
    }

    provisioner_args = nil

    assert_difference("GithubRepositoryLink.count", 1) do
      Github::WebhookProvisioner.stub(:ensure_for_links, ->(**kwargs) { provisioner_args = kwargs }) do
        patch creative_github_integration_path(@creative), params: payload, as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal payload[:repositories].sort, body["selected_repositories"].sort

    details = body.fetch("webhooks")
    assert_equal "existing-secret", details["sample-user/example"]["secret"]

    new_details = details["sample-user/another"]
    assert new_details["secret"].present?
    assert new_details["url"].end_with?("/github/webhook")

    link = GithubRepositoryLink.find_by!(repository_full_name: "sample-user/another")
    assert_equal new_details["secret"], link.webhook_secret

    assert provisioner_args.present?, "Expected webhook provisioner to be invoked"
    assert_equal @github_account.id, provisioner_args[:account].id
    assert_equal github_webhook_url, provisioner_args[:webhook_url]
    returned_links = provisioner_args[:links]
    assert_equal payload[:repositories].sort, returned_links.map(&:repository_full_name).sort

    assert_equal 'Updated prompt: #{pr_title} #{diff}', body["github_gemini_prompt"]
    assert_equal 'Updated prompt: #{pr_title} #{diff}', @creative.reload.github_gemini_prompt
  end

  test "non admin users cannot manage github integration" do
    other_user = users(:two)
    CreativeShare.create!(creative: @creative, user: other_user, permission: :write)

    sign_out
    sign_in_as(other_user, password: "password")

    get creative_github_integration_path(@creative), as: :json
    assert_response :forbidden

    payload = { repositories: [ "sample-user/example" ] }
    patch creative_github_integration_path(@creative), params: payload, as: :json
    assert_response :forbidden
  end

  test "destroy removes repository links for creative" do
    removal_args = nil

    Github::WebhookProvisioner.stub(:remove_for_repositories, ->(**kwargs) { removal_args = kwargs }) do
      assert_difference("GithubRepositoryLink.count", -1) do
        delete creative_github_integration_path(@creative), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)

    assert body["success"], "Expected success flag in response"
    assert_equal [], body["selected_repositories"], "Expected no repositories after deletion"
    assert_equal({}, body["webhooks"])
    assert_empty @creative.github_repository_links.where(github_account: @github_account)

    assert_equal @github_account.id, removal_args[:account].id
    assert_equal github_webhook_url, removal_args[:webhook_url]
    assert_equal [ "sample-user/example" ], removal_args[:repositories]
  end

  test "destroy removes single repository when repository param provided" do
    GithubRepositoryLink.create!(
      creative: @creative,
      github_account: @github_account,
      repository_full_name: "sample-user/another",
      webhook_secret: "another-secret"
    )

    assert_difference("GithubRepositoryLink.count", -1) do
      delete creative_github_integration_path(@creative),
             params: { repository: "sample-user/example" },
             as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal [ "sample-user/another" ], body["selected_repositories"], "Expected remaining repository to be returned"
    assert body["webhooks"].key?("sample-user/another"), "Expected webhook info for remaining repo"
    assert_not body["webhooks"].key?("sample-user/example"), "Expected deleted repo to be absent"
    remaining = @creative.github_repository_links.where(github_account: @github_account).pluck(:repository_full_name)
    assert_equal [ "sample-user/another" ], remaining
  end
end
