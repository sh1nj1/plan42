module Collavre
  # Instruments "<model>_created.collavre" once a record is committed, e.g.
  # "comment_created.collavre" with { comment:, user: }. `user` is whoever
  # created the record (see #creation_event_actor), not necessarily its owner.
  # Listeners such as the notice bar's Notices::Tracker react without coupling
  # to the model.
  module CreationEvents
    extend ActiveSupport::Concern

    included do
      after_create_commit :instrument_created_event
    end

    private

    def instrument_created_event
      name = model_name.element
      ActiveSupport::Notifications.instrument("#{name}_created.collavre", name.to_sym => self, user: creation_event_actor)
    end

    def creation_event_actor
      user
    end
  end
end
