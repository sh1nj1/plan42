module Collavre
  module UsersController::ContactManagement
    extend ActiveSupport::Concern

    def search
      term = params[:q].to_s.strip.downcase

      if term.blank? && params[:scope] != "contacts"
        return render json: []
      end

      creative = Collavre::Creative.find_by(id: params[:creative_id])

      if creative.present? && !creative.has_permission?(Current.user, :read)
        head :forbidden and return
      end

      scope = if params[:scope] == "contacts" && Current.user
        # Include both contacts and searchable users (e.g., AI agents with searchable=true)
        contact_ids = Current.user.contact_users.select(:id)
        searchable_ids = Collavre::User.where(searchable: true).select(:id)
        Collavre::User.where(id: contact_ids).or(Collavre::User.where(id: searchable_ids))
      else
        Collavre::User.mentionable_for(creative)
      end

      users = scope
      if term.present?
        users = users.where("LOWER(users.email) LIKE :term OR LOWER(users.name) LIKE :term", term: "#{term}%")
      end

      limit = params[:limit].to_i
      limit = 20 if limit <= 0
      limit = 50 if limit > 50

      user_ids = users.select(:id).distinct.limit(limit).pluck(:id)
      users = Collavre::User.where(id: user_ids)
      render json: users.map { |u| { id: u.id, name: u.display_name, email: u.email, avatar_url: view_context.user_avatar_url(u, size: 20) } }
    end

    private

    def prepare_org_chart
      # 1. Creatives with actual shares relevant to current user
      shared_creative_ids = Collavre::Creative.shared_accessible_ids(Current.user)

      # 2. Walk up ancestor chains to build full paths (A > B > C)
      all_tree_ids = Set.new(shared_creative_ids)
      Collavre::Creative.where(id: shared_creative_ids).find_each do |creative|
        creative.ancestors.each { |a| all_tree_ids.add(a.id) }
      end

      # 3. Build the tree
      all_creatives = Collavre::Creative.where(id: all_tree_ids.to_a).order(:sequence, :id)
      @org_chart_roots = all_creatives.select { |c| c.parent_id.nil? || !all_tree_ids.include?(c.parent_id) }
      @org_chart_children = all_creatives.select { |c| c.parent_id.present? && all_tree_ids.include?(c.parent_id) }.group_by(&:parent_id)

      # 4. Preload shares
      shares = Collavre::CreativeShare
        .where(creative_id: all_tree_ids.to_a)
        .includes(user: [ avatar_attachment: :blob ], shared_by: [ avatar_attachment: :blob ])
      @org_chart_shares = shares.group_by(&:creative_id)

      # 5. Preload pending invitations
      @org_chart_invitations = Collavre::Invitation
        .where(creative_id: all_tree_ids.to_a, accepted_at: nil)
        .where("expires_at > ?", Time.current)
        .order(created_at: :desc)
        .group_by(&:creative_id)

      # 6. Unassigned AI Agents: owned by current user but not in any CreativeShare
      assigned_user_ids = shares.map(&:user_id).uniq
      @org_chart_unassigned = Collavre::User.where(created_by_id: Current.user.id)
                                            .where.not(id: assigned_user_ids)
                                            .where.not(llm_vendor: [ nil, "" ])
                                            .includes(avatar_attachment: :blob)
                                            .order(:name)
    end
  end
end
