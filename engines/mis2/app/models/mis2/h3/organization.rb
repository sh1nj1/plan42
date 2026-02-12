module Mis2
  module H3
    class Organization < Mis2::H3Record
      self.table_name = "organization"
      self.inheritance_column = nil

      TYPES = %w[SUPERIOR_GENERAL_HOSPITAL GENERAL_HOSPITAL HOSPITAL CLINIC NURSING_HOSPITAL HEALTH_AGENCY].freeze

      has_many :departments,
        class_name: "Mis2::H3::OrganizationDepartment",
        foreign_key: "organization_id"

      def self.type_label(value)
        I18n.t("mis2.h3.organizations.types.#{value&.downcase}", default: value)
      end

      def type_label
        self.class.type_label(type)
      end
    end
  end
end
