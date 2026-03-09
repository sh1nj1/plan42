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

    def prepare_contacts
      per_page = 20
      @contact_page = [ params[:contact_page].to_i, 1 ].max

      creative_shares = Collavre::CreativeShare.arel_table
      creatives = Collavre::Creative.arel_table

      user_creative_origins_sql = Collavre::Creative
        .where(user_id: Current.user.id)
        .select("COALESCE(origin_id, id) AS origin_id")
        .to_sql

      shared_by_me_scope = Collavre::CreativeShare
        .joins(:creative)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])
        .where(
          creative_shares[:shared_by_id].eq(Current.user.id)
            .or(
              creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].eq(Current.user.id))
            )
            .or(
              creatives[:id].in(Arel.sql("(#{user_creative_origins_sql})"))
            )
        )

      shared_with_me_scope = Collavre::CreativeShare
        .joins(:creative)
        .where(user_id: Current.user.id)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])

      contact_ids_sql = [
        Current.user.contacts.select("contact_user_id AS user_id").to_sql,
        shared_by_me_scope.select("creative_shares.user_id AS user_id").to_sql,
        shared_with_me_scope.select("COALESCE(creative_shares.shared_by_id, creatives.user_id) AS user_id").to_sql
      ].join(" UNION ")

      contact_users_relation = Collavre::User.where(
        id: Collavre::User.from("(#{contact_ids_sql}) AS contact_ids").select(:user_id)
      )

      @total_contacts = contact_users_relation.count
      @total_contact_pages = [ (@total_contacts.to_f / per_page).ceil, 1 ].max
      paged_users = contact_users_relation
        .includes(avatar_attachment: :blob)
        .order(:name, :id)
        .offset((@contact_page - 1) * per_page)
        .limit(per_page)

      existing_contacts = Current.user.contacts.includes(contact_user: [ avatar_attachment: :blob ]).index_by(&:contact_user_id)
      @contacts = paged_users.map do |user|
        existing_contacts[user.id] || Collavre::Contact.new(user: Current.user, contact_user: user)
      end

      shares_from_me = shared_by_me_scope
        .where(user_id: paged_users.map(&:id))
        .includes(:creative)

      @shared_by_me = shares_from_me.group_by(&:user_id).transform_values { |shares| shares.map(&:creative) }

      shares_to_me = Collavre::CreativeShare
        .joins(:creative)
        .where(user_id: Current.user.id)
        .where.not(permission: Collavre::CreativeShare.permissions[:no_access])
        .where(
          creative_shares[:shared_by_id].in(paged_users.map(&:id))
            .or(creative_shares[:shared_by_id].eq(nil).and(creatives[:user_id].in(paged_users.map(&:id))))
        )
        .includes(:creative)

      @shared_with_me = shares_to_me.group_by(&:sharer_id)
                                    .transform_values { |shares| shares.map(&:creative) }
    end

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

      # 4. Preload shares (including origin shares for linked creatives)
      origin_ids = all_creatives.filter_map(&:origin_id).uniq
      share_lookup_ids = (all_tree_ids.to_a + origin_ids).uniq
      shares = Collavre::CreativeShare
        .where(creative_id: share_lookup_ids)
        .includes(user: [ avatar_attachment: :blob ], shared_by: [ avatar_attachment: :blob ])
      shares_by_creative = shares.group_by(&:creative_id)

      # Map shares: linked creatives inherit from origin if they have no direct shares
      @org_chart_shares = {}
      all_creatives.each do |c|
        direct = shares_by_creative.fetch(c.id, [])
        if direct.empty? && c.origin_id.present?
          @org_chart_shares[c.id] = shares_by_creative.fetch(c.origin_id, [])
        else
          @org_chart_shares[c.id] = direct
        end
      end

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
