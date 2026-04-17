module Collavre
  class CreativeSharesController < ApplicationController
    def index
      @creative = Creative.find(params[:creative_id])
      unless @creative.has_permission?(Current.user, :admin)
        head :forbidden and return
      end

      @shared_list = CreativeShare.where(creative: @creative)
                                  .includes(user: [ avatar_attachment: :blob ])

      # Build inherited shares from ancestor creatives
      @inherited_shares = build_inherited_shares(@creative)

      @pending_invitations = Invitation.where(creative: @creative, accepted_at: nil)
                                       .where("expires_at > ?", Time.current)
                                       .order(created_at: :desc)

      render partial: "collavre/creatives/share_modal", layout: false
    end

    def create
      @creative = Creative.find(params[:creative_id]).effective_origin

      unless @creative.has_permission?(Current.user, :admin)
        respond_to do |format|
          format.html { redirect_back fallback_location: creatives_path, alert: t("collavre.creatives.errors.no_permission") }
          format.json { render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden }
        end
        return
      end

      user = nil
      if params[:user_email].present?
        user = User.find_by(email: params[:user_email])
        unless user
          invitation = Invitation.create!(email: params[:user_email], inviter: Current.user, creative: @creative, permission: params[:permission])
          InvitationMailer.with(invitation: invitation).invite.deliver_later
          respond_to do |format|
            format.html { redirect_back fallback_location: creatives_path, notice: t("collavre.invites.invite_sent") }
            format.json { render json: { notice: t("collavre.invites.invite_sent") }, status: :created }
          end
          return
        end

        # Restrict sharing non-searchable AI agents to their owners only
        if user.ai_user? && !user.searchable? && user.created_by_id != Current.user.id
          respond_to do |format|
            format.html { redirect_back fallback_location: creatives_path, alert: t("collavre.creatives.share.cannot_share_private_ai_agent") }
            format.json { render json: { error: t("collavre.creatives.share.cannot_share_private_ai_agent") }, status: :forbidden }
          end
          return
        end
      end

      permission = params[:permission]

      # Enforce read-only for public shares (no user email provided)
      if params[:user_email].blank? && permission != "no_access" && permission != "read"
        permission = "read"
      end

      ancestor_ids = @creative.ancestors.pluck(:id)
      ancestor_shares = CreativeShare.where(creative_id: ancestor_ids, user: user)
                                     .where("permission >= ? or permission = ?", CreativeShare.permissions[permission], CreativeShare.permissions[:no_access])
      closest_parent_share = CreativeShare.closest_parent_share(ancestor_ids, ancestor_shares)

      is_param_no_access = permission == :no_access.to_s
      Rails.logger.debug "### closest_parent_share = #{closest_parent_share.inspect}, is_param_no_access: #{is_param_no_access}"
      if closest_parent_share.present?
        if closest_parent_share.permission == :no_access.to_s
          respond_to do |format|
            format.html { redirect_back fallback_location: creatives_path, alert: t("collavre.creatives.share.can_not_share_by_no_access_in_parent") }
            format.json { render json: { error: t("collavre.creatives.share.can_not_share_by_no_access_in_parent") }, status: :unprocessable_entity }
          end
          return
        else
          unless is_param_no_access
            respond_to do |format|
              format.html { redirect_back fallback_location: creatives_path, alert: t("collavre.creatives.share.already_shared_in_parent") }
              format.json { render json: { error: t("collavre.creatives.share.already_shared_in_parent") }, status: :unprocessable_entity }
            end
            return
          end
        end
      end

      share = CreativeShare.find_or_initialize_by(creative: @creative, user: user)
      share.shared_by ||= Current.user
      share.permission = permission
      if share.save and not is_param_no_access
        if user
          @creative.create_linked_creative_for_user(user)
          Contact.ensure(user: Current.user, contact_user: user)
          Contact.ensure(user: @creative.user, contact_user: user)
        end
        respond_to do |format|
          format.html { redirect_back fallback_location: creatives_path, notice: t("collavre.creatives.share.shared") }
          format.json { render json: { notice: t("collavre.creatives.share.shared") }, status: :created }
        end
      else
        respond_to do |format|
          format.html { redirect_back fallback_location: creatives_path, alert: share.errors.full_messages.to_sentence }
          format.json { render json: { error: share.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    def update
      @creative_share = find_admin_creative_share(params[:id])

      if @creative_share.update(permission: params[:permission])
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.creatives.share.permission_updated") }
          format.json { render json: { permission: @creative_share.permission }, status: :ok }
        end
      else
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: @creative_share.errors.full_messages.to_sentence }
          format.json { render json: { error: @creative_share.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    def destroy
      @creative_share = find_admin_creative_share(params[:id])

      @creative_share.destroy
      # remove linked creative if it exists
      linked_creative = Creative.find_by(origin_id: @creative_share.creative_id, user_id: @creative_share.user_id)
      linked_creative&.destroy
      respond_to do |format|
        format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.creatives.index.share_deleted") }
        format.json { head :no_content }
      end
    end

    private

      # Scoped lookup: only returns the share if Current.user has admin permission
      # on its creative. Raises ActiveRecord::RecordNotFound otherwise so that
      # record existence is not leaked via 403 vs 404 distinction.
      def find_admin_creative_share(id)
        share = CreativeShare.find_by(id: id)
        raise ActiveRecord::RecordNotFound unless share&.creative&.has_permission?(Current.user, :admin)

        share
      end

      def all_descendants(creative)
        creative.children.flat_map { |child| [ child ] + all_descendants(child) }
      end

      # Returns inherited shares from ancestor creatives.
      # Each entry is a hash with :share, :source_creative keys.
      # Only includes the closest (most specific) share per user.
      def build_inherited_shares(creative)
        ancestors = creative.ancestors
        return [] if ancestors.empty?

        ancestor_ids = ancestors.pluck(:id)
        direct_user_ids = CreativeShare.where(creative: creative).pluck(:user_id).compact

        ancestor_shares = CreativeShare
          .where(creative_id: ancestor_ids)
          .where.not(user_id: direct_user_ids) # Exclude users who already have direct shares
          .includes(:creative, user: [ avatar_attachment: :blob ])

        # Group by user_id and pick the closest ancestor share
        ancestor_shares.group_by(&:user_id).filter_map do |_user_id, shares|
          closest = CreativeShare.closest_parent_share(ancestor_ids, shares)
          next unless closest && closest.permission != "no_access"

          { share: closest, source_creative: closest.creative }
        end
      end
  end
end
