module Mis2
  module H2
    class OrganizationsController < Mis2::ApplicationController
      def search
        query = params[:query].to_s.strip
        if query.present?
          organizations = Mis2::H2::Organization.search_by_name(query)
          render json: organizations.map { |org|
            {
              organization_idx: org.organization_idx,
              organization_name: org.organization_name
            }
          }
        else
          render json: []
        end
      end
    end
  end
end
