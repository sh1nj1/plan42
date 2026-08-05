module Collavre
module Creatives
  # Single source of truth for "which request params narrow the creative index
  # view" and "is any filter currently active". Previously this list was
  # duplicated (with drifting coverage) across CreativesController,
  # IndexQuery and the search form partial. Centralizing it keeps the active
  # indicator, the reset flow and the client-side persistence agreeing on one
  # definition.
  module FilterParams
    module_function

    # Every param that, when present, means the user has narrowed the view.
    # Used for the "active" indicator (the highlighted search trigger), the
    # controller's progress/cache gating, and — serialized to the client — the
    # localStorage persistence + reset flow.
    #
    # show_archived is a *display* filter: it lights the active indicator and
    # affects progress display, but it does NOT route the query through
    # FilterPipeline (archived visibility is handled by the base scope). Hence
    # ROUTING_KEYS excludes it.
    DISPLAY_KEYS = %w[
      tags
      min_progress
      max_progress
      search
      comment
      has_comments
      due_before
      due_after
      has_due_date
      assignee_id
      unassigned
      show_archived
    ].freeze

    # Params that route the query through FilterPipeline (everything except the
    # archived-visibility toggle).
    ROUTING_KEYS = (DISPLAY_KEYS - %w[show_archived]).freeze

    # Whether any of the given filter keys is active for the request params.
    # Accepts anything indexable by string key (Hash, ActionController::Parameters,
    # HashWithIndifferentAccess).
    def active?(params, keys = DISPLAY_KEYS)
      keys.any? { |key| present?(params, key) }
    end

    def present?(params, key)
      value = params[key.to_s]
      if key.to_s == "comment"
        value.to_s == "true"
      else
        value.respond_to?(:present?) ? value.present? : !value.nil?
      end
    end
  end
end
end
