module Collavre
  class CreativeSharesController < ApplicationController
    def index
      @creative = Creative.find(params[:creative_id])
      unless @creative.has_permission?(Current.user, :admin)
        head :forbidden and return
      end

      @shared_list = CreativeShare.where(creative: @creative)
                                  .includes(user: [ avatar_attachment: :blob ])

      @pending_invitations = Invitation.where(creative: @creative, accepted_at: nil)
                                       .where("expires_at > ?", Time.current)
                                       .order(created_at: :desc)

      render partial: "collavre/creatives/share_modal", layout: false
    end

    def create
      @creative = Creative.find(params[:creative_id]).effective_origin

      unless @creative.has_permission?(Current.user, :admin)
        flash[:alert] = t("collavre.creatives.errors.no_permission")
        redirect_back(fallback_location: creatives_path) and return
      end

      user = nil
      if params[:user_email].present?
        user = User.find_by(email: params[:user_email])
        unless user
          invitation = Invitation.create!(email: params[:user_email], inviter: Current.user, creative: @creative, permission: params[:permission])
          InvitationMailer.with(invitation: invitation).invite.deliver_later
          flash[:notice] = t("collavre.invites.invite_sent")
          redirect_back(fallback_location: creatives_path) and return
        end

        # Restrict sharing non-searchable AI agents to their owners only
        if user.ai_user? && !user.searchable? && user.created_by_id != Current.user.id
          flash[:alert] = t("collavre.creatives.share.cannot_share_private_ai_agent")
          redirect_back(fallback_location: creatives_path) and return
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
          flash[:alert] = t("collavre.creatives.share.can_not_share_by_no_access_in_parent")
          redirect_back(fallback_location: creatives_path) and return
        else
          if is_param_no_access
            # can set!
          else
            flash[:alert] = t("collavre.creatives.share.already_shared_in_parent")
            redirect_back(fallback_location: creatives_path) and return
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
        flash[:notice] = t("collavre.creatives.share.shared")
      else
        flash[:alert] = share.errors.full_messages.to_sentence
      end
      redirect_back(fallback_location: creatives_path)
    end

    def update
      @creative_share = CreativeShare.find(params[:id])
      unless @creative_share.creative.has_permission?(Current.user, :admin)
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: t("collavre.creatives.errors.no_permission") }
          format.json { render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden }
        end
        return
      end

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
      @creative_share = CreativeShare.find(params[:id])
      unless @creative_share.creative.has_permission?(Current.user, :admin)
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: t("collavre.creatives.errors.no_permission") }
          format.json { render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden }
        end
        return
      end

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

      def all_descendants(creative)
        creative.children.flat_map { |child| [ child ] + all_descendants(child) }
      end
  end
end
