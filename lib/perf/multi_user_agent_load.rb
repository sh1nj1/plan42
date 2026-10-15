# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"
require_relative "fake_llm_server"
require_relative "load_report"

module Perf
  # Load test for "N people each driving M agents at the same time".
  #
  # Shape (defaults: 10 users x 4 agents = 40 concurrent turns):
  # - M shared agents, all pointed at a FakeLlmServer that holds every turn open
  #   for `llm_seconds`, like a real provider stream.
  # - Each user owns a workspace creative with one topic per agent, pinned to
  #   that agent. Topics are the unit of agent concurrency, so this is the only
  #   shape in which one user can have M turns running at once.
  # - Every user logs in over HTTP and posts one message into each of their M
  #   topics simultaneously, then keeps reading their chat (the UI's comments
  #   list) until every turn has finished.
  #
  # Runs inside `bin/rails runner` against the same database as a live server at
  # `base_url` (that server's Puma threads, Solid Queue workers and cache are
  # what is being measured). Fixture rows are tagged perf-* and reused across
  # runs.
  class MultiUserAgentLoad
    PASSWORD = "perf-password-123"
    EMAIL_DOMAIN = "perf.collavre.test"

    def initialize(base_url:, users: 10, agents: 4, llm_seconds: 20, timeout: 300, probe_interval: 0.5,
                   slo: {}, log: $stdout)
      @base_url = base_url.chomp("/")
      @user_count = users
      @agent_count = agents
      @llm_seconds = llm_seconds
      @timeout = timeout
      @probe_interval = probe_interval
      @slo = slo
      @log = log
      @run_id = "PERF-#{SecureRandom.hex(3)}"
    end

    def run
      llm = FakeLlmServer.new(stream_seconds: @llm_seconds, tag_pattern: /#{@run_id}-[\w-]+/).start
      fixtures = Fixtures.new(user_count: @user_count, agent_count: @agent_count, gateway_url: llm.base_url).prepare!
      log "fixtures ready: #{fixtures.users.size} users, #{fixtures.agents.size} agents, llm=#{llm.base_url}"

      sessions = fixtures.users.each_with_index.map do |user, index|
        HttpSession.new(@base_url, client_ip: "198.51.100.#{index + 1}").tap { |s| s.login!(user.email, PASSWORD) }
      end
      log "logged in #{sessions.size} users; posting #{expected_turns} messages (run #{@run_id})"

      posts, probes, outcomes = drive(fixtures, sessions)
      build_report(posts, llm, probes, outcomes)
    ensure
      llm&.stop
    end

    private

    def expected_turns
      @user_count * @agent_count
    end

    def drive(fixtures, sessions)
      started_at = Time.current
      done = false
      probes = Queue.new
      probe_threads = sessions.each_with_index.map do |session, index|
        Thread.new { probe_loop(session, fixtures.workspaces[index], fixtures.topics[index], probes) { done } }
      end
      posts = post_all(fixtures, sessions)
      outcomes = wait_for_turns(fixtures, posts, started_at)
      done = true
      probe_threads.each(&:join)
      [ posts, drain(probes), outcomes ]
    end

    def post_all(fixtures, sessions)
      gate = Queue.new
      threads = sessions.each_with_index.flat_map do |session, user_index|
        fixtures.topics[user_index].each_with_index.map do |topic, agent_index|
          tag = "#{@run_id}-u#{user_index + 1}-a#{agent_index + 1}"
          Thread.new do
            gate.pop
            session.post_comment(fixtures.workspaces[user_index], topic, "load check #{tag}").merge(tag: tag)
          end
        end
      end
      threads.size.times { gate << true }
      threads.map(&:value)
    end

    def probe_loop(session, workspace, topics, probes)
      topics.cycle do |topic|
        break if yield

        probes << session.read_comments(workspace, topic)
        sleep @probe_interval
      end
    end

    def wait_for_turns(fixtures, posts, started_at)
      deadline = monotonic + @timeout
      loop do
        # rails runner wraps the script in the query cache; polling must not hit it.
        statuses = ActiveRecord::Base.uncached { turn_statuses(fixtures, posts, started_at) }
        settled = statuses.size == posts.size && statuses.values.none? { |s| Collavre::Task::ACTIVE_STATUSES.include?(s) }
        return statuses.values.tally if settled || monotonic > deadline

        sleep 1
      end
    end

    # Final status per posted message: the task answering it, or "missing".
    def turn_statuses(fixtures, posts, started_at)
      tags = posts.map { |post| post[:tag] }
      comment_tags = Collavre::Comment.where(creative_id: fixtures.workspaces.map(&:id))
                                      .where("created_at >= ?", started_at - 1)
                                      .pluck(:id, :content)
                                      .to_h { |id, content| [ id, tag_of(content) ] }
                                      .select { |_id, tag| tags.include?(tag) }
      tasks = Collavre::Task.where(agent_id: fixtures.agents.map(&:id)).where("created_at >= ?", started_at - 1)
      by_tag = tasks.each_with_object({}) do |task, result|
        tag = comment_tags[task.trigger_event_payload&.dig("comment", "id")]
        result[tag] = task.status if tag
      end
      tags.to_h { |tag| [ tag, by_tag.fetch(tag, "missing") ] }
    end

    # The whole tag, so "-a1" never claims an "-a10" message.
    def tag_of(content)
      content.to_s[/#{Regexp.escape(@run_id)}-u\d+-a\d+(?!\d)/]
    end

    def build_report(posts, llm, probes, outcomes)
      LoadReport.new(
        expected_turns: expected_turns,
        posts: posts,
        llm: llm.requests.map(&:to_h),
        probes: probes,
        outcomes: outcomes,
        peak_llm: llm.peak_in_flight,
        slo: @slo,
        meta: { run_id: @run_id, users: @user_count, agents: @agent_count, llm_seconds: @llm_seconds,
                base_url: @base_url, rails_env: Rails.env, at: Time.current.iso8601 }
      )
    end

    def drain(queue)
      Array.new(queue.size) { queue.pop }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(message)
      @log.puts("[perf] #{message}")
    end

    # Idempotent perf-* users, agents, workspaces, shares and pinned topics.
    class Fixtures
      attr_reader :users, :agents, :workspaces, :topics

      def initialize(user_count:, agent_count:, gateway_url:)
        @user_count = user_count
        @agent_count = agent_count
        @gateway_url = gateway_url
      end

      def prepare!
        @users = Array.new(@user_count) { |i| human("perf-user-#{i + 1}") }
        @agents = Array.new(@agent_count) { |i| agent("perf-agent-#{i + 1}") }
        @workspaces = @users.map { |user| workspace(user) }
        @topics = @workspaces.map { |creative| @agents.map { |agent| pinned_topic(creative, agent) } }
        settle_previous_runs!
        self
      end

      private

      def human(name)
        user = Collavre::User.find_or_initialize_by(email: "#{name}@#{EMAIL_DOMAIN}")
        user.assign_attributes(name: name, password: PASSWORD, email_verified_at: user.email_verified_at || Time.current)
        user.save!
        user.unlock_account! if user.respond_to?(:unlock_account!) && user.locked?
        user
      end

      def agent(name)
        agent = Collavre::User.find_or_initialize_by(email: "#{name}@#{EMAIL_DOMAIN}")
        agent.assign_attributes(name: name, password: PASSWORD, llm_vendor: "openai", llm_model: "perf-fake",
                                gateway_url: @gateway_url, system_prompt: "You are a load-test agent. Reply briefly.",
                                tools: [], searchable: false)
        agent.save!
        allow_one_turn_per_user!(agent)
        agent
      end

      # Every user drives every agent at once, so each agent must be allowed
      # one turn per user; the default per-agent cap (5) would otherwise make
      # the run fail as soon as the scheduler enforces it.
      def allow_one_turn_per_user!(agent)
        policy = Collavre::OrchestratorPolicy.find_or_initialize_by(scope_type: "User", scope_id: agent.id,
                                                                    policy_type: "scheduling")
        policy.update!(enabled: true, config: policy.config.merge(
          "max_concurrent_jobs" => @user_count,
          "rate_limit_per_minute" => [ @user_count, Collavre::Orchestration::PolicyResolver::DEFAULTS.dig("scheduling", "rate_limit_per_minute") ].max
        ))
      end

      # Grants are built synchronously: the shares' own PermissionCacheJobs run
      # on the authz queue, and a comment posted before they land is routed to
      # no agent and only surfaces as "missing" at the timeout.
      def workspace(user)
        Collavre::Creative.find_or_create_by!(user: user, description: "Perf workspace #{user.name}")
                          .tap { |creative| Collavre::Creatives::PermissionCacheBuilder.cache_owner(creative) }
      end

      def pinned_topic(creative, agent)
        share = Collavre::CreativeShare.find_or_initialize_by(creative: creative, user: agent)
        share.update!(permission: :feedback, shared_by: creative.user) unless share.persisted? && share.feedback?
        Collavre::Creatives::PermissionCacheBuilder.propagate_share(share)
        topic = Collavre::Topic.find_or_create_by!(creative: creative, name: agent.name) { |t| t.user = creative.user }
        topic.set_primary_agent!(agent) unless topic.primary_agent_id == agent.id
        topic
      end

      # A previous aborted run can leave turns holding topic and agent slots.
      def settle_previous_runs!
        Collavre::Task.where(agent_id: @agents.map(&:id), status: Collavre::Task::ACTIVE_STATUSES)
                      .find_each { |task| task.update_columns(status: "cancelled") }
        @agents.each { |agent| Collavre::Orchestration::ResourceTracker.for(agent).reset! }
      end
    end

    # One logged-in browser: cookie jar + CSRF token, timing every request.
    # Each person gets their own client address (TEST-NET-2, forwarded through
    # the loopback proxy hop) so per-IP limits such as the login rate limit see
    # ten people, not one.
    class HttpSession
      def initialize(base_url, client_ip: nil)
        @uri = URI(base_url)
        @client_ip = client_ip
        @cookies = {}
      end

      def login!(email, password)
        login_page = request(Net::HTTP::Get.new("/session/new"))
        form = { email: email, password: password, authenticity_token: token_from(login_page.body, "csrf-token") }
        post = Net::HTTP::Post.new("/session")
        post.set_form_data(form)
        response = request(post)
        raise "login failed for #{email}: HTTP #{response.code}" unless response.is_a?(Net::HTTPRedirection)

        @csrf = token_from(follow(response["location"]).body, "csrf-token")
        raise "no CSRF token after login for #{email}" unless @csrf
      end

      def post_comment(creative, topic, content)
        post = Net::HTTP::Post.new("/creatives/#{creative.id}/comments")
        post["Content-Type"] = "application/json"
        post["X-CSRF-Token"] = @csrf
        post.body = JSON.generate(comment: { content: content, topic_id: topic.id })
        timed(post) { |response| response.code == "201" }
      end

      # The chat panel's own request: the topic's comment list, as HTML.
      def read_comments(creative, topic)
        get = Net::HTTP::Get.new("/creatives/#{creative.id}/comments?topic_id=#{topic.id}")
        timed(get) { |response| response.is_a?(Net::HTTPSuccess) }
      end

      private

      def timed(req)
        posted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = request(req)
        { posted_at: posted_at, latency: Process.clock_gettime(Process::CLOCK_MONOTONIC) - posted_at,
          ok: yield(response), status: response.code.to_i }
      rescue IOError, SystemCallError, Timeout::Error, Net::HTTPBadResponse => e
        { posted_at: posted_at, latency: nil, ok: false, error: e.class.name }
      end

      def follow(location, hops: 5)
        uri = URI(location.to_s)
        response = request(Net::HTTP::Get.new(uri.respond_to?(:request_uri) ? uri.request_uri : uri.to_s))
        return response unless response.is_a?(Net::HTTPRedirection) && hops.positive?

        follow(response["location"], hops: hops - 1)
      end

      def request(req)
        req["X-Forwarded-For"] = @client_ip if @client_ip
        req["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ") if @cookies.any?
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", read_timeout: 60) do |http|
          http.request(req)
        end
        Array(response.get_fields("set-cookie")).each do |cookie|
          key, value = cookie.split(";", 2).first.split("=", 2)
          @cookies[key] = value
        end
        response
      end

      def token_from(html, name)
        html.to_s[/name="#{Regexp.escape(name)}"[^>]*(?:value|content)="([^"]+)"/, 1] ||
          html.to_s[/(?:value|content)="([^"]+)"[^>]*name="#{Regexp.escape(name)}"/, 1]
      end
    end
  end
end
