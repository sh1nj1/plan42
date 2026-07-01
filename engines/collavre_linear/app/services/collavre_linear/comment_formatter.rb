# frozen_string_literal: true

module CollavreLinear
  # Builds the Linear-facing body for a Collavre comment.
  #
  # Every Collavre chat participant reaches Linear through one shared app actor,
  # so their comments would otherwise be indistinguishable on the Linear side.
  # Prefixing the author's display name ("[정순오]: ...") preserves attribution.
  #
  # The same formatter drives the inbound echo guard: when Linear webhooks our
  # own comment back, the incoming body equals this prefixed form, so the
  # applier can recognise the echo and leave the canonical local comment intact.
  module CommentFormatter
    module_function

    def outbound_body(comment)
      content = comment.content.to_s
      author  = comment.user&.display_name
      author.present? ? "[#{author}]: #{content}" : content
    end
  end
end
