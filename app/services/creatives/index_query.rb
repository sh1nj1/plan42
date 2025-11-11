module Creatives
  class IndexQuery
    Result = Struct.new(
      :creatives,
      :parent_creative,
      :shared_creative,
      :shared_list,
      :overall_progress,
      keyword_init: true
    )

    def initialize(user:, params: {})
      @user = user
      @params = params.with_indifferent_access
    end

    def call
      creatives, parent = resolve_creatives
      shared_creative = parent || creatives&.first
      shared_list = shared_creative ? shared_creative.all_shared_users : []
      overall_progress = calculate_progress(creatives)

      Result.new(
        creatives: creatives,
        parent_creative: parent,
        shared_creative: shared_creative,
        shared_list: shared_list,
        overall_progress: overall_progress
      )
    end

    private

    attr_reader :user, :params

    def resolve_creatives
      if params[:comment] == "true"
        creatives = Creative
                      .joins(:comments)
                      .where.not(comments: { id: nil })
                      .select { |c| readable?(c) }
                      .uniq(&:id)
        creatives = creatives.sort_by { |c| c.comments.maximum(:updated_at) || c.updated_at }.reverse
        [ creatives, nil ]
      elsif params[:search].present?
        search_creatives
      elsif params[:id]
        creative = Creative.where(id: params[:id])
                            .order(:sequence)
                            .detect { |c| readable?(c) }
        [ creative&.children_with_permission(user, :read), creative ]
      else
        [ Creative.where(user: user).roots, nil ]
      end
    end

    def search_creatives
      query = "%#{params[:search]}%"
      if params[:simple].present?
        creatives = Creative
                      .joins(:rich_text_description)
                      .where("action_text_rich_texts.body LIKE :q", q: query)
                      .select { |c| readable?(c) }
        [ creatives, nil ]
      elsif params[:id].present?
        base_creative = Creative.find_by(id: params[:id])&.effective_origin
        return [ [], nil ] unless base_creative

        subtree_ids = base_creative.subtree_ids
        creatives = Creative
                      .distinct
                      .joins(:rich_text_description)
                      .left_joins(:comments)
                      .where(id: subtree_ids)
                      .where("action_text_rich_texts.body LIKE :q OR comments.content LIKE :q", q: query)
                      .select { |c| readable?(c) }
        [ creatives, base_creative ]
      else
        creatives = Creative
                      .distinct
                      .joins(:rich_text_description)
                      .left_joins(:comments)
                      .where("action_text_rich_texts.body LIKE :q OR comments.content LIKE :q", q: query)
                      .where(origin_id: nil)
                      .select { |c| readable?(c) }
        [ creatives, nil ]
      end
    end

    def calculate_progress(creatives)
      return unless params[:tags].present?
      tag_ids = Array(params[:tags]).map(&:to_s)
      roots = creatives || []
      progress_values = roots.map { |c| c.progress_for_tags(tag_ids, user) }.compact
      progress_values.any? ? progress_values.sum.to_f / progress_values.size : 0
    end

    def readable?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end
  end
end
