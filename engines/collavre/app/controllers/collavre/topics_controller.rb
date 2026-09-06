module Collavre
  class TopicsController < ApplicationController
    rescue_from Topics::TopicMove::SourceChangedError, with: :render_source_changed
    rescue_from Topics::TopicMove::MoveBlockedError, with: :render_active_tasks

    include Collavre::CreativePermissionGuard

    before_action :set_creative
    before_action :require_creative_read!, only: %i[index next_name channel_chips]
    before_action :require_creative_admin!, only: %i[update destroy move reorder]
    before_action :require_creative_write!, only: %i[create archive unarchive set_primary_agent]

    include Collavre::Topics::ReservedTopicGuard

    def index
      is_owner = @creative.user == Current.user
      can_manage = @creative.has_permission?(Current.user, :admin) || is_owner
      # Mirrors require_creative_write! — the gate on #create and
      # #set_primary_agent. Reported as two capabilities because the client gates
      # two separate controls on it, and only #update/#destroy/#move/#reorder
      # need :admin.
      can_write = can_manage || @creative.has_permission?(Current.user, :write)

      # Eagerly ensure Main (and System for inboxes) exist BEFORE loading
      # active_topics. Otherwise the first inbox visit sees no System topic in
      # the sidebar, and when a later notification creates it via
      # find_or_create_by!, the unread badge appears but the user has no way to
      # open the topic.
      main_topic = @creative.main_topic(fallback_user: Current.user)
      system_topic = @creative.inbox? ? @creative.system_topic(fallback_user: Current.user) : nil

      active_topics = @creative.topics.active.includes(primary_agent: { avatar_attachment: :blob }).order(:created_at)
      archived_topics = @creative.topics.archived.includes(primary_agent: { avatar_attachment: :blob }).order(:created_at)
      unread_counts_by_topic = Creatives::CommentBadgeIndex.new(user: Current.user)
        .unread_counts_by_topic(@creative)

      main_topic_id = main_topic.id
      @cron_badge_decorator = Topics::CronBadgeDecorator.new(@creative, main_topic_id, can_write, view_context)

      render json: {
        topics: active_topics.map { |t| topic_json(t, unread_count: unread_counts_by_topic.fetch(t.id, 0)) },
        archived_topics: archived_topics.map { |t| topic_json(t, unread_count: unread_counts_by_topic.fetch(t.id, 0)) },
        can_manage: can_manage,
        can_create_topic: can_write,
        can_set_primary_agent: can_write,
        **Topics::LastTopicPreferencePayload.new(creative: @creative, user: Current.user).call,
        is_inbox: @creative.inbox?,
        system_topic_id: system_topic&.id,
        main_topic_id: main_topic_id,
        effective_creative_id: @creative.id
      }
    end

    def create
      requested_agent = params[:agent_id].present? ? User.find_by(id: params[:agent_id]) : nil

      # No topic yet, so a Claude Channel agent is rejected on an inbox creative:
      # a topic created here never carries a session_id, which is the only place
      # Matcher#eligible_in_inbox? will route one.
      rejection = requested_agent&.ai_user? &&
        Topic.primary_agent_rejection(@creative, requested_agent)
      if rejection
        render json: { errors: [ unassignable_agent_message(requested_agent, rejection) ] },
               status: :unprocessable_entity and return
      end

      topic = @creative.topics.build(topic_params)
      topic.user = Current.user

      Topic.transaction do
        if topic.save
          agent = nil
          if requested_agent&.ai_user?
            agent = requested_agent
            topic.set_primary_agent!(agent)
          end

          # Move comments to the new topic if comment_ids provided
          comment_ids = Array(params[:comment_ids]).map(&:presence).compact
          if comment_ids.any?
            CommentMoveService.new(creative: @creative, user: Current.user).call(
              comment_ids: comment_ids,
              target_topic_id: topic.id
            )
          end

          broadcast_data = agent ? topic_json_with_agent(topic, agent) : topic.slice(:id, :name)
          broadcast_topic_event("created", topic: broadcast_data, user_id: Current.user.id)
          render json: topic, status: :created
        else
          render json: { errors: topic.errors.full_messages }, status: :unprocessable_entity
        end
      end
    rescue CommentMoveService::MoveError => e
      render json: { errors: [ e.message ] }, status: :unprocessable_entity
    end

    def next_name
      render json: { name: generate_next_topic_name }
    end

    def channel_chips
      topic = @creative.topics.find(params[:id])
      render partial: "collavre/comments/channel_chips", locals: { topic: topic }
    end

    def update
      topic = @creative.topics.find(params[:id])

      if mutate_locked_topic(topic) { |current_topic| current_topic.update(topic_params) }
        broadcast_topic_event("updated", topic: topic_json(topic))
        render json: topic_json(topic)
      else
        render json: { errors: topic.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      topic = @creative.topics.find(params[:id])

      topic_id, topic_name = Topics::TopicDestroy.new(
        topic: topic, source_creative: @creative
      ).call

      # Best-effort recurring-cron cleanup and notice. Must never break the
      # core deletion: if it raises, swallow + log so broadcast/head still run.
      begin
        Collavre::Topics::OrphanedCronNotifier.new(
          topic_id: topic_id,
          topic_name: topic_name
        ).call
      rescue StandardError => e
        Rails.logger.error(
          "[TopicsController#destroy] OrphanedCronNotifier failed for topic " \
          "#{topic_id}: #{e.class} #{e.message}"
        )
      end

      broadcast_topic_event("deleted", topic_id: topic_id)
      head :no_content
    end

    def move
      topic = @creative.topics.find(params[:id])
      source_creative = @creative
      target_creative = Creative.find(params[:target_creative_id]).effective_origin

      unless target_creative.has_permission?(Current.user, :write) || target_creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.move.no_target_permission") }, status: :forbidden and return
      end

      # Check for duplicate topic name in target creative
      if target_creative.topics.where(name: topic.name).exists?
        render json: { error: I18n.t("collavre.topics.move.duplicate_name", name: topic.name) }, status: :unprocessable_entity and return
      end

      # A Claude Channel session topic is looked up as
      # inbox.topics.find_by(primary_agent_id:, session_id:) — re-parenting it
      # takes it out of that scope, so the next registration would fork a second
      # topic and Matcher#eligible_in_inbox? would stop routing the session
      # agent. Same identity that #set_primary_agent refuses to rewrite.
      if topic.session_id.present?
        render json: { error: I18n.t("collavre.topics.move.session_topic_locked") }, status: :unprocessable_entity and return
      end

      effects = Topics::TopicMoveEffects.new(topic, source_creative, target_creative)
      released_agent, released_reason = Topics::TopicMove.new(
        topic: topic, target_creative: target_creative
      ).call(after_commit: effects.method(:call))

      render json: {
        success: true,
        topic: topic.slice(:id, :name),
        target_creative_id: target_creative.id,
        target_creative_name: target_creative.creative_snippet,
        missing_members: missing_members_for_move(source_creative, target_creative),
        released_primary_agent: released_agent && {
          id: released_agent.id,
          name: released_agent.display_name,
          message: released_primary_agent_message(released_agent, released_reason, target_creative)
        }
      }
    end

    def archive
      topic = @creative.topics.find(params[:id])
      mutate_locked_topic(topic, &:archive!)

      broadcast_topic_event("archived", topic: topic.slice(:id, :name))
      render json: { success: true }
    end

    def unarchive
      topic = @creative.topics.find(params[:id])
      mutate_locked_topic(topic, &:unarchive!)

      broadcast_topic_event("unarchived", topic: topic.slice(:id, :name, :archived_at))
      render json: { success: true }
    end

    def reorder
      topic_ids = params[:topic_ids]
      unless topic_ids.is_a?(Array) && topic_ids.present?
        render json: { error: "Invalid topic_ids" }, status: :unprocessable_entity and return
      end

      Topic.transaction do
        topic_ids.each_with_index do |id, index|
          @creative.topics.where(id: id).update_all(position: index)
        end
      end

      broadcast_topic_event("reordered", topic_ids: topic_ids)

      render json: { success: true }
    end

    def set_primary_agent
      topic = @creative.topics.find(params[:id])

      # On a Claude Channel session topic, primary_agent_id is not a routing pin
      # but part of the session identity: Matcher#eligible_in_inbox? needs it to
      # route the session agent at all, and SessionProvisioner#find_or_create_topic
      # reuses the topic by (primary_agent_id, session_id). Clearing or reassigning
      # it would leave a live session unroutable and split the next registration
      # into a second topic. Releasing a session is session teardown, not an
      # avatar click.
      if topic.session_id.present?
        render json: { error: I18n.t("collavre.topics.session_topic_locked") },
               status: :unprocessable_entity and return
      end

      # A blank agent_id clears the assignment. The primary agent is an exclusive
      # assignment (it silences every other agent's ambient routing), so the user
      # needs a way back to an unassigned topic — otherwise a single avatar click
      # would permanently dedicate the topic to one agent.
      if params[:agent_id].blank?
        mutate_locked_topic(topic) { |current_topic| current_topic.set_primary_agent!(nil) }

        broadcast_topic_event("updated", topic: topic_json_with_agent(topic, nil))

        return render json: { success: true, topic: topic_json_with_agent(topic, nil) }
      end

      agent = User.find_by(id: params[:agent_id])

      unless agent&.ai_user?
        render json: { error: I18n.t("collavre.topics.not_ai_agent") }, status: :unprocessable_entity and return
      end

      rejection = Topic.primary_agent_rejection(@creative, agent, topic: topic)
      if rejection
        render json: { error: unassignable_agent_message(agent, rejection) },
               status: :unprocessable_entity and return
      end

      mutate_locked_topic(topic) { |current_topic| current_topic.set_primary_agent!(agent) }

      broadcast_topic_event("updated", topic: topic_json_with_agent(topic, agent))

      render json: { success: true, topic: topic_json_with_agent(topic, agent) }
    end

    private

    def render_source_changed(error)
      render json: { error: error.message }, status: :forbidden
    end

    def render_active_tasks(error)
      render json: { error: error.message }, status: :unprocessable_entity
    end

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
    end

    def mutate_locked_topic(topic, &) = Topics::TopicMutation.new(topic: topic, source_creative: @creative).call(&)

    # A move can now release the pin for either reason, and the advice differs:
    # sharing the target creative fixes a missing-permission release, but a
    # Claude Channel session agent stays confined to its own session topic no
    # matter what is shared — telling the user to share and re-assign would send
    # them after a fix that cannot work.
    def released_primary_agent_message(agent, rejection, target_creative)
      key = if rejection == :session_agent_outside_session_topic
              "collavre.topics.move.primary_agent_released_session_agent"
      else
              "collavre.topics.move.primary_agent_released"
      end

      I18n.t(key, agent: agent.display_name, creative: target_creative.creative_snippet)
    end

    def unassignable_agent_message(agent, rejection)
      if rejection == :session_agent_outside_session_topic
        I18n.t("collavre.topics.session_agent_not_assignable", name: agent.display_name)
      else
        I18n.t("collavre.topics.agent_no_creative_access", name: agent.display_name)
      end
    end

    # When a topic moves to a different creative, members who had access on the
    # source creative may lose visibility on the target. Returns the human
    # members who are effectively present on the source (owner + feedback-or-
    # higher shares) but have no resolvable access on the target, so the client
    # can offer to re-add them with the same permission. Only returned when the
    # current user can actually grant shares on the target (admin/owner);
    # otherwise the suggestion would be unusable.
    def missing_members_for_move(source_creative, target_creative)
      return [] unless target_creative.has_permission?(Current.user, :admin) || target_creative.user == Current.user

      # Any user with a resolvable share on the target chain (including inherited
      # shares and explicit no_access blocks) already has — or is intentionally
      # denied — access, so they are never "missing".
      excluded_user_ids = target_creative.all_shared_users(:no_access).map(&:user_id).compact.to_set
      excluded_user_ids << target_creative.user_id
      excluded_user_ids << Current.user&.id

      # Candidate => grant permission. Source owner had full control, so we
      # suggest admin; shared members keep their own (closest) permission.
      candidates = {}
      owner = source_creative.user
      if owner && !owner.ai_user? && excluded_user_ids.exclude?(owner.id)
        candidates[owner.id] = { user: owner, permission: "admin" }
      end

      source_creative.all_shared_users(:feedback).each do |share|
        user = share.user
        next if user.nil? || user.ai_user?
        next if excluded_user_ids.include?(user.id)

        candidates[user.id] ||= { user: user, permission: share.permission }
      end

      candidates.values.map do |candidate|
        {
          user: view_context.user_json(candidate[:user], email: true),
          permission: candidate[:permission]
        }
      end
    end


    def topic_params
      params.require(:topic).permit(:name)
    end

    def generate_next_topic_name
      Topics::NextName.for(@creative)
    end

    # Delegated to Topics::Serializer so the topic MCP tools, which broadcast the
    # same events from outside a request, cannot describe a topic differently
    # from this controller.
    def topic_json(topic, unread_count: nil)
      data = Topics::Serializer.call(topic, unread_count: unread_count)
      @cron_badge_decorator ? @cron_badge_decorator.call(data, topic) : data
    end

    # Always carries a :primary_agent key, explicitly nil when cleared. The client
    # merges this payload into its cached topic, so an omitted key would leave a
    # stale avatar on screen instead of removing it.
    def topic_json_with_agent(topic, agent)
      Topics::Serializer.with_agent(topic, agent)
    end

    def agent_json(agent)
      view_context.user_json(agent)
    end

    def broadcast_topic_event(action, creative: @creative, **payload)
      TopicsChannel.broadcast_to(creative, { action: action, **payload })
    end
  end
end
