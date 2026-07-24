module Collavre
  module UsersController::Registration
    extend ActiveSupport::Concern

    included do
      allow_unauthenticated_access only: %i[new create exists]
      before_action -> { enforce_auth_provider!(:email) }, only: [ :new, :create ]
    end

    def new
      @user = Collavre::User.new
      if params[:invite_token].present?
        @invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
        @user.email = @invitation&.email
      end
    end

    def create
      @user = Collavre::User.new(user_params)
      Collavre::Invitation.transaction do
        if params[:invite_token].present?
          invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
          if invitation
            @invitation = invitation
            @user.email = invitation.email
          end
        end
        if @user.save
          if invitation
            invitation.update(accepted_at: Time.current)
            Collavre::CreativeShare.create!(
              creative: invitation.creative,
              user: @user,
              permission: invitation.permission,
              shared_by: invitation.inviter
            )
            Collavre::Contact.ensure(user: invitation.inviter, contact_user: @user)
            invitation.creative.create_linked_creative_for_user(@user)
          end
          # Deployments with no outbound mail (e.g. the local desktop app, which
          # has no SMTP/SES) would otherwise leave the first user unable to verify
          # and permanently locked out of login. Such envs opt into auto-verify.
          # NB: compare to `true` explicitly — an unset config.x.* key reads back
          # as a truthy empty OrderedOptions, so a bare `if` would fire everywhere.
          if Rails.application.config.x.auto_verify_email == true
            @user.update_column(:email_verified_at, Time.current)
          else
            Collavre::EmailVerificationMailer.verify(@user).deliver_later
          end
          # Envs that ship no seeded admin (e.g. desktop) bootstrap one here: the
          # first registered user becomes system_admin. Guarded by "no admin yet"
          # so only the very first signup is elevated, and by a loopback origin so
          # that in documented open mode (LAN/Tailscale binding) a remote client
          # cannot race the local owner for the admin account. `== true` for the
          # same OrderedOptions reason as above.
          if Rails.application.config.x.bootstrap_first_admin == true && request_from_loopback?
            # Promote atomically rather than exists?-then-update: a separate check
            # and write is a TOCTOU race where two concurrent first signups both
            # read "no admin yet" and both elevate. A single UPDATE ... WHERE NOT
            # EXISTS lets the DB evaluate the guard and write under one lock, so
            # exactly one wins. This path only runs on desktop (the only env that
            # sets bootstrap_first_admin), which is always SQLite — and SQLite
            # serializes writers, so the loser's re-evaluated NOT EXISTS sees the
            # admin and updates nothing.
            admin_exists = Collavre::User.where(system_admin: true).arel.exists
            Collavre::User.where(id: @user.id).where(admin_exists.not).update_all(system_admin: true)
          end
          session.delete(:return_to_after_authenticating)
          redirect_to new_session_path, notice: I18n.t("collavre.users.new.success_sign_up")
        else
          render :new, status: :unprocessable_entity
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        flash.now[:alert] = I18n.t("collavre.invites.invalid")
        render :new, status: :unprocessable_entity
      end
    end

    def exists
      user = Collavre::User.find_by(email: params[:email])
      render json: { exists: user.present? }
    end

    private

    # Whether the request originates from the local machine. Uses remote_addr
    # (the socket peer) rather than remote_ip: remote_ip trusts X-Forwarded-For
    # from private-range proxies, so a LAN attacker at e.g. 192.168.x could spoof
    # `XFF: 127.0.0.1` and forge a loopback origin. The socket peer cannot be
    # spoofed by headers.
    def request_from_loopback?
      addr = IPAddr.new(request.remote_addr.to_s)
      addr = addr.native if addr.respond_to?(:ipv4_mapped?) && addr.ipv4_mapped?
      addr.loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def user_params
      params.require(:user).permit(:email, :password, :password_confirmation, :name)
    end
  end
end
