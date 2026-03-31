module Collavre
  class CreativesController < ApplicationController
    include Collavre::Concerns::SlideViewable
    include Collavre::Concerns::Exportable
    include Collavre::Concerns::TreeManageable
    include Collavre::Concerns::Shareable

    # TODO: for not for security reasons for this Collavre app, we don't expose to public, later it should be controlled by roles for each Creatives
    # Removed unauthenticated access to index and show actions
    allow_unauthenticated_access only: %i[ index children export_markdown show slide_view ]
    before_action :enforce_creatives_login_policy, only: %i[ index children export_markdown show slide_view ]
    before_action :set_creative, only: %i[ show edit update destroy parent_suggestions slide_view request_permission unconvert contexts update_contexts update_metadata archive unarchive trigger_action ]

    def index
      respond_to do |format|
        format.html do
          # HTML only needs parent_creative for nav/title - skip expensive filtered queries
          # Must check permission to avoid leaking metadata (og:title, etc.) to unauthorized users
          if params[:id].present?
            creative = Creative.find_by(id: params[:id])
            @parent_creative = creative if creative&.has_permission?(Current.user, :read)
          end
          @creatives = []  # CSR will fetch via JSON
          @shared_list = @parent_creative ? @parent_creative.all_shared_users : []
        end
        format.json do
          # Full query only for JSON requests
          user_id_for_state = Current.user&.id
          if user_id_for_state.nil? && params[:id].present?
            # Public view: use owner's state
            target_creative = Creative.find_by(id: params[:id])
            user_id_for_state = target_creative&.effective_origin&.user_id
          end

          @expanded_state_map = if user_id_for_state
            UserCreativePreference.where(user_id: user_id_for_state, creative_id: params[:id]).first&.expanded_status || {}
          else
            {}
          end
          index_result = ::Creatives::IndexQuery.new(user: Current.user, params: params.to_unsafe_h).call
          @creatives = index_result.creatives || []
          @parent_creative = index_result.parent_creative
          @shared_creative = index_result.shared_creative
          @shared_list = index_result.shared_list
          @overall_progress = index_result.overall_progress if any_filter_active?
          @allowed_creative_ids = index_result.allowed_creative_ids
          @progress_map = index_result.progress_map

          # Set filtered_progress on parent creative if progress_map is available
          if @parent_creative && @progress_map && @progress_map.key?(@parent_creative.id.to_s)
            @parent_creative.filtered_progress = @progress_map[@parent_creative.id.to_s]
          end

          # Disable caching for filtered results to ensure fresh data
          expires_now if any_filter_active?

          if params[:simple].present?
            render json: serialize_creatives(@creatives)
          else
            @creatives_tree_json = build_tree(
              index_result.creatives,
              params: params,
              expanded_state_map: @expanded_state_map,
              level: 1,
              allowed_creative_ids: @allowed_creative_ids,
              progress_map: @progress_map
            )
            render json: { creatives: @creatives_tree_json }
          end
        end
      end
    end

    def show
      unless @creative.has_permission?(Current.user, :read)
        if Current.user
          redirect_to creatives_path, alert: t("collavre.creatives.errors.no_permission")
        else
          request_authentication
        end
        return
      end

      respond_to do |format|
        redirect_options = { id: @creative.id }
        redirect_options[:comment_id] = params[:comment_id] if params[:comment_id].present?
        format.html { redirect_to creatives_path(redirect_options) }
        format.json do
          # Use HTTP caching with ETag - must vary by user since response includes user-specific data
          # ETag must also include prompt comment and children timestamps since those are in response
          effective = @creative.effective_origin
          cache_user = Current.user&.id || "anon"

          # Include prompt comment timestamp (user-specific private comments starting with "> ")
          # Note: LIKE '> %' uses index prefix scan if available; consider dedicated prompt flag if bottleneck
          prompt_updated = if Current.user
            @creative.comments
              .where(private: true, user: Current.user)
              .where("content LIKE ?", "> %")
              .maximum(:updated_at)
          end

          # Get children stats in a single query, reuse for has_children
          # Use separate Arel.sql args so pick returns an array; unscope order to avoid Postgres aggregate error
          children_count, children_max_updated = @creative.children
            .unscope(:order)
            .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(updated_at)"))
          children_count = children_count.to_i  # Handle nil and string type-casting from adapters
          children_key = "#{children_count}-#{children_max_updated&.to_i}"

          last_modified = [
            @creative.updated_at,
            effective.updated_at,
            prompt_updated
          ].compact.max

          etag = [
            "creative",
            @creative.cache_key_with_version,
            effective.cache_key_with_version,
            "user",
            cache_user,
            "prompt",
            prompt_updated&.to_i,
            "children",
            children_key,
            "trigger_v1"
          ].join(":")

          trigger_loop_data = @creative.data&.dig("trigger", "loop")
          Rails.logger.info "[TRIGGER_DEBUG] creative_id=#{@creative.id} trigger_loop=#{trigger_loop_data&.dig('state')} etag=#{etag.truncate(80)}"

          if stale?(etag: etag, last_modified: last_modified, public: false)
            root = params[:root_id] ? Creative.find_by(id: params[:root_id]) : nil
            depth = if root
                      (@creative.ancestors.count - root.ancestors.count) + 1
            else
                      @creative.ancestors.count + 1
            end
            render json: {
              id: @creative.id,
              description: @creative.effective_description,
              description_raw_html: @creative.description,
              origin_id: @creative.origin_id,
              parent_id: @creative.parent_id,
              progress: @creative.progress,
              progress_html: view_context.render_creative_progress(@creative),
              depth: depth,
              prompt: @creative.prompt_for(Current.user),
              has_children: children_count > 0,
              data: @creative.effective_origin(Set.new).data,
              trigger_loop: trigger_loop_data,
              can_edit: @creative.has_permission?(Current.user, :write)
            }
          end
        end
      end
    end

    def new
      @creative = Creative.new
      if params[:parent_id].present?
        @parent_creative = Creative.find_by(id: params[:parent_id])
        @creative.parent = @parent_creative if @parent_creative
      end
      if params[:child_id].present?
        @child_creative = Creative.find_by(id: params[:child_id])
      end
      if params[:after_id].present?
        @after_creative = Creative.find_by(id: params[:after_id])
      end
    end

    def create
      result = Creatives::CreateService.new(
        creative_params: creative_params,
        user: Current.user,
        child_id: params[:child_id],
        before_id: params[:before_id],
        after_id: params[:after_id],
        tag_ids: params[:tags]
      ).call

      @creative = result.creative

      if result.success?
        render json: { id: @creative.id }
      else
        render json: { errors: result.errors }, status: :unprocessable_entity
      end
    end

    def parent_suggestions
      suggestions = ::GeminiParentRecommender.new.recommend(@creative)
      render json: suggestions
    end

    def edit
      unless @creative.has_permission?(Current.user, :write)
        redirect_to @creative, alert: t("collavre.creatives.errors.no_permission") and return
      end
      if params[:inline]
        render partial: "inline_edit_form"
      end
    end

    def update
      respond_to do |format|
        permitted = creative_params.to_h
        base = @creative.effective_origin(Set.new)
        success = true
        previous_progress = base.progress
        requested_progress = permitted["progress"] || permitted[:progress]

        # Require write permission for origin content changes (description, progress, sequence)
        origin_changes = permitted.except("parent_id")
        if origin_changes.any? && !@creative.has_permission?(Current.user, :write)
          format.html { redirect_to @creative, alert: t("collavre.creatives.errors.no_permission") }
          format.json { render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden }
          next
        end

        # Handle parent_id change separately for Linked Creatives
        if @creative.origin_id.present? && permitted.key?("parent_id")
          parent_id = permitted.delete("parent_id")
          success &&= @creative.update(parent_id: parent_id)
        end

        # When updating the base (Origin), we must NOT pass origin_id.
        # Because if @creative is Linked, params might include origin_id.
        # Passing origin_id to the Origin creative causes it to fail validation (cannot changes if has origin)
        # or creates a self-cycle.
        permitted.delete("origin_id")
        permitted.delete(:origin_id)

        success &&= base.update(permitted)
        if success && requested_progress.present? && requested_progress.to_f >= 1 && previous_progress.to_f < 1
          if base.children.exists?
            base.self_and_descendants.where(origin_id: nil)
              .update_all(progress: 1.0, updated_at: Time.current)
          end
        end

        if success
          format.html { redirect_to @creative }
          format.json do
            base.reload
            response_data = {
              id: base.id,
              progress: base.progress,
              progress_html: view_context.render_creative_progress(base),
              has_children: base.children.exists?
            }
            # Build ancestor chain for progress updates (closure_tree: 1 SELECT via hierarchy table)
            ancestor_records = base.ancestors.order(:id)
            if ancestor_records.any?
              response_data[:ancestors] = ancestor_records.map do |anc|
                {
                  id: anc.id,
                  progress: anc.progress,
                  progress_html: view_context.render_creative_progress(anc, has_children: true)
                }
              end
            end
            render json: response_data
          end
        else
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: { errors: @creative.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def contexts
      creative = @creative.effective_origin(Set.new)
      own_ids = creative.context_ids - [ creative.id ]
      inherited_ids = (creative.effective_context_ids - own_ids - [ creative.id ]).uniq
      own_creatives = Creative.where(id: own_ids).index_by(&:id)
      inherited_creatives = Creative.where(id: inherited_ids).index_by(&:id)

      disabled_ids = Array(creative.data&.dig("disabled_context_ids"))

      own = own_ids.filter_map do |cid|
        c = own_creatives[cid]
        next unless c

        { id: c.id, description: c.creative_snippet, inherited: false, disabled: disabled_ids.include?(cid) }
      end

      inherited = inherited_ids.filter_map do |cid|
        c = inherited_creatives[cid]
        next unless c

        { id: c.id, description: c.creative_snippet, inherited: true, disabled: disabled_ids.include?(cid) }
      end

      render json: {
        contexts: inherited + own,
        can_manage: creative.has_permission?(Current.user, :admin),
        disabled_self_context: creative.data&.dig("disabled_self_context") == true
      }
    end

    def update_contexts
      creative = @creative.effective_origin(Set.new)
      unless creative.has_permission?(Current.user, :admin)
        render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden
        return
      end

      current_data = (creative.data || {}).dup
      current_data["context_ids"] = Array(params[:context_ids]).map(&:to_i) if params.key?(:context_ids)
      current_data["disabled_context_ids"] = Array(params[:disabled_context_ids]).map(&:to_i) if params.key?(:disabled_context_ids)
      current_data.delete("disabled_context_ids") if current_data["disabled_context_ids"]&.empty?
      if params.key?(:disabled_self_context)
        if ActiveModel::Type::Boolean.new.cast(params[:disabled_self_context])
          current_data["disabled_self_context"] = true
        else
          current_data.delete("disabled_self_context")
        end
      end

      if creative.update(data: current_data)
        head :ok
      else
        render json: { errors: creative.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update_metadata
      creative = @creative.effective_origin(Set.new)
      unless creative.has_permission?(Current.user, :write)
        render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden
        return
      end

      new_data = begin
        JSON.parse(params[:data])
      rescue JSON::ParserError => e
        render json: { error: "Invalid JSON: #{e.message}" }, status: :unprocessable_entity
        return
      end
      previous_enabled = creative.drop_trigger_enabled?

      if creative.update(data: new_data)
        notify_drop_trigger_missing_agent!(creative) if !previous_enabled && creative.drop_trigger_enabled?
        head :ok
      else
        render json: { errors: creative.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def trigger_action
      action = params[:action_name] || (request.content_type&.include?("json") ? request.request_parameters["action"] : params[:action])

      case action
      when "toggle_container"
        # Container toggle operates on effective_origin (where trigger config lives)
        creative = @creative.effective_origin(Set.new)
        unless creative.has_permission?(Current.user, :write)
          render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden
          return
        end

        enabled = ActiveModel::Type::Boolean.new.cast(
          request.content_type&.include?("json") ? request.request_parameters["enabled"] : params[:enabled]
        )
        data = creative.data || {}
        trigger = data["trigger"] || {}
        trigger["on_child_enter"] = enabled
        data["trigger"] = trigger
        previous_enabled = creative.drop_trigger_enabled?
        creative.update!(data: data)
        notify_drop_trigger_missing_agent!(creative) if !previous_enabled && creative.drop_trigger_enabled?
      when "pause", "resume", "restart"
        # Loop actions operate on the creative itself (where loop state lives)
        creative = @creative
        unless creative.has_permission?(Current.user, :write)
          render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden
          return
        end

        data = creative.data || {}
        trigger = data["trigger"] || {}
        loop_data = trigger["loop"]

        case action
        when "pause"
          if loop_data && %w[running pending_verification].include?(loop_data["state"])
            loop_data["state"] = "paused"
            trigger["loop"] = loop_data
            data["trigger"] = trigger
            creative.update!(data: data)
          end
        when "resume"
          if loop_data && %w[paused idle stuck].include?(loop_data["state"])
            loop_data["state"] = "running"
            trigger["loop"] = loop_data
            data["trigger"] = trigger
            creative.update!(data: data)
            post_continue_to_agent(creative, loop_data)
          end
        when "restart"
          if loop_data && %w[completed max_reached stuck].include?(loop_data["state"])
            loop_data["state"] = "running"
            loop_data["current_iteration"] = 0
            loop_data["infra_retry_count"] = 0
            trigger["loop"] = loop_data
            data["trigger"] = trigger
            creative.update!(data: data)
            post_restart_trigger(creative)
          end
        end
      else
        render json: { error: "Unknown action" }, status: :unprocessable_entity
        return
      end

      head :ok
    end

    def archive
      unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
        render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden and return
      end

      @creative.archive!
      head :ok
    end

    def unarchive
      unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
        render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden and return
      end

      @creative.unarchive!
      head :ok
    end

    def destroy
      parent = @creative.parent
      unless @creative.has_permission?(Current.user, :admin)
        redirect_to @creative, alert: t("collavre.creatives.errors.no_permission") and return
      end
      Creatives::DestroyService.new(
        creative: @creative,
        user: Current.user,
        delete_with_children: params[:delete_with_children].present?
      ).call
    end

    private
      def build_tree(collection, params:, expanded_state_map:, level:, select_mode: false, allowed_creative_ids: nil, progress_map: nil)
        ::Creatives::TreeBuilder.new(
          user: Current.user,
          params: params,
          view_context: view_context,
          expanded_state_map: expanded_state_map,
          select_mode: select_mode,
          max_level: Current.user&.display_level || User::DEFAULT_DISPLAY_LEVEL,
          allowed_creative_ids: allowed_creative_ids,
          progress_map: progress_map
        ).build(collection, level: level)
      end

      def set_creative
        @creative = Creative.find(params[:id])
      end

      def creative_params
        params.require(:creative).permit(:description, :progress, :parent_id, :sequence, :origin_id)
      end

      def any_filter_active?
        params[:tags].present? ||
          params[:min_progress].present? ||
          params[:max_progress].present? ||
          params[:search].present? ||
          params[:comment] == "true" ||
          params[:has_comments].present? ||
          params[:due_before].present? ||
          params[:due_after].present? ||
          params[:has_due_date].present? ||
          params[:assignee_id].present? ||
          params[:unassigned].present? ||
          params[:show_archived].present?
      end

      def serialize_creatives(collection)
        if params[:simple].present?
          collection.map { |c| { id: c.id, description: c.effective_description(nil, false), progress: c.progress } }
        else
          collection.map { |c| { id: c.id, description: c.effective_description, progress: c.progress } }
        end
      end

      def reorderer
        @reorderer ||= ::Creatives::Reorderer.new(user: Current.user)
      end

      # Resume: post a continue instruction so the agent picks up where it left off.
      # Creates a comment that triggers dispatch via after_create_commit.
      def post_continue_to_agent(creative, loop_data)
        parent = creative.parent
        unless parent
          Rails.logger.warn("[TriggerAction] resume: no parent for creative #{creative.id}")
          return
        end

        topic = creative.topics.find_by(name: "Drop Trigger")
        agent = parent.all_shared_users(:write).map(&:user).find(&:ai_user?)
        unless topic && agent
          Rails.logger.warn("[TriggerAction] resume: missing topic=#{topic&.id} or agent for creative #{creative.id}")
          return
        end

        iteration = loop_data["current_iteration"] || 0
        max = loop_data["max_iterations"] || 10
        content = "@#{agent.name}: #{t(
          'collavre.trigger_loop.continue',
          iteration: iteration,
          max: max
        )}"

        # Use Current.user (human who clicked resume) as comment author
        # so dispatch_to_orchestration doesn't skip it (it skips ai_user? authors)
        comment = creative.comments.create!(
          content: content,
          topic_id: topic.id,
          private: false,
          user: Current.user,
          skip_dispatch: false
        )
        Rails.logger.info("[TriggerAction] resume: posted continue comment #{comment.id} for creative #{creative.id}")
      end

      # Restart: create a fresh trigger comment and dispatch it explicitly.
      # Uses skip_dispatch:true + manual SystemEvents dispatch to bypass
      # after_create_commit (which would skip if user is ai_user?).
      def post_restart_trigger(creative)
        parent = creative.parent
        unless parent
          Rails.logger.warn("[TriggerAction] restart: no parent for creative #{creative.id}")
          return
        end

        topic = creative.topics.find_by(name: "Drop Trigger")
        agent = parent.all_shared_users(:write).map(&:user).find(&:ai_user?)
        unless topic && agent
          Rails.logger.warn("[TriggerAction] restart: missing topic=#{topic&.id} or agent for creative #{creative.id}")
          return
        end

        trigger_text = t(
          "collavre.drop_trigger.child_entered",
          child_description: creative.creative_snippet,
          child_id: creative.id,
          parent_description: parent.creative_snippet
        )
        loop_instructions = t("collavre.trigger_loop.instructions")
        content = "@#{agent.name}: #{trigger_text}\n\n#{loop_instructions}"

        comment = creative.comments.create!(
          content: content,
          topic_id: topic.id,
          private: false,
          user: Current.user,
          skip_dispatch: true
        )

        scheduled = SystemEvents::Dispatcher.dispatch("comment_created", comment.dispatch_payload)
        Rails.logger.info("[TriggerAction] restart: posted trigger comment #{comment.id}, dispatched to #{scheduled&.size || 0} agents")
      end

      def notify_drop_trigger_missing_agent!(creative)
        return if creative.all_shared_users(:write).map(&:user).any?(&:ai_user?)

        topic = creative.topics.find_or_create_by!(name: "Drop Trigger") do |t|
          t.user = creative.user
        end

        creative.comments.create!(
          content: t("collavre.drop_trigger.no_agent", parent_description: creative.creative_snippet),
          topic_id: topic.id,
          private: false,
          skip_default_user: true
        )
      end

      def enforce_creatives_login_policy
        if SystemSetting.creatives_login_required?
          require_authentication
        end
      end
  end
end
