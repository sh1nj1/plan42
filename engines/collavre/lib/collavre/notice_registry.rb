# frozen_string_literal: true

module Collavre
  # Registry for the notices shown in the top notice bar: product announcements,
  # new-feature guides and onboarding missions. Definitions live in code (copy in
  # config/locales/notices.*.yml) and per-user progress lives in UserNotice, so
  # vendor engines can register their own notices without a data migration.
  #
  # @example Registering an onboarding mission
  #   Collavre::NoticeRegistry.register(:first_creative,
  #     kind: :mission,
  #     group: :onboarding,
  #     icon: "🌱",
  #     target: ".new-root-creative-btn",
  #     cta_path: ->(routes, _user) { routes.creatives_path },
  #     done_when: ->(user) { Collavre::Creative.where(user: user).exists? },
  #     completes_on: { "creative_created.collavre" => true })
  class NoticeRegistry
    include Singleton

    def initialize
      @notices = {}
      @mutex = Mutex.new
    end

    def register(key, config = {})
      notice = NoticeDefinition.new(key, config)
      @mutex.synchronize { @notices[notice.key] = notice }
      notice
    end

    def unregister(key)
      @mutex.synchronize { @notices.delete(key.to_sym) }
    end

    def find(key)
      return if key.blank?

      @mutex.synchronize { @notices[key.to_sym] }
    end

    # Definitions in registration order; a group's missions run in this order.
    def all
      @mutex.synchronize { @notices.values }
    end

    def group(name)
      all.select { |notice| notice.group == name&.to_sym }
    end

    def listening_to(event_name)
      all.select { |notice| notice.listens_to?(event_name) }
    end

    def reset!
      @mutex.synchronize { @notices = {} }
    end

    # Boot hook: re-registers the engine's notices on every code reload and
    # routes domain events to Notices::Tracker.
    def install
      ActiveSupport::Notifications.subscribe(/\.collavre\z/) do |event|
        Collavre::Notices::Tracker.handle(event.name, event.payload)
      end
      registry = self
      Rails.application.config.to_prepare do
        registry.reset!
        OnboardingNotices.register
      end
    end

    class << self
      delegate :register, :unregister, :find, :all, :group, :listening_to, :reset!, :install, to: :instance
    end
  end

  # One registered notice. Missions stay until their completion condition holds;
  # the other kinds leave once the user closes them or follows the call to action.
  class NoticeDefinition
    KINDS = %i[urgent mission announcement feature].freeze
    DEFAULT_PRIORITY = { urgent: 0, mission: 1, announcement: 2, feature: 2 }.freeze
    KEY_FORMAT = /\A[a-z0-9_]+\z/
    HUMANS_ONLY = ->(user) { !user.ai_user? }

    attr_reader :key, :kind, :priority, :icon, :group, :target, :starts_at, :ends_at, :completes_on

    def initialize(key, config)
      @key = key.to_sym
      @kind = config.fetch(:kind, :announcement).to_sym
      @priority = config.fetch(:priority) { DEFAULT_PRIORITY[@kind] }
      @icon = config[:icon]
      @group = config[:group]&.to_sym
      @target = config[:target]
      @cta_path = config[:cta_path]
      @done_when = config[:done_when]
      @completes_on = (config[:completes_on] || {}).transform_keys(&:to_s)
      @audience = config.fetch(:audience, HUMANS_ONLY)
      @starts_at = config[:starts_at]
      @ends_at = config[:ends_at]

      validate!
    end

    def mission?
      kind == :mission
    end

    def i18n_scope
      "collavre.notices.items.#{key}"
    end

    def active?(now = Time.current)
      (starts_at.nil? || starts_at <= now) && (ends_at.nil? || ends_at > now)
    end

    def visible_to?(user)
      user.present? && @audience.call(user)
    end

    def done_for?(user)
      @done_when.present? && @done_when.call(user)
    end

    def listens_to?(event_name)
      completes_on.key?(event_name.to_s)
    end

    # Whether an instrumented event finishes this notice. `true` trusts the
    # event itself; a proc inspects the payload; anything else defers to
    # done_when so the check matches what a page load would conclude.
    def completed_by?(event_name, payload, user)
      rule = completes_on[event_name.to_s]
      return rule.call(payload) if rule.respond_to?(:call)
      return true if rule == true

      done_for?(user)
    end

    def cta_path(routes, user)
      @cta_path.respond_to?(:call) ? @cta_path.call(routes, user) : @cta_path
    end

    private

    def validate!
      raise ArgumentError, "Notice key #{key.inspect} must match #{KEY_FORMAT.inspect}" unless key.to_s.match?(KEY_FORMAT)
      raise ArgumentError, "Notice #{key.inspect} has unknown kind #{kind.inspect}" unless KINDS.include?(kind)
      raise ArgumentError, "Mission #{key.inspect} needs a :group" if mission? && group.nil?
      raise ArgumentError, "Mission #{key.inspect} needs :done_when or :completes_on" if mission? && @done_when.nil? && completes_on.empty?
    end
  end
end
