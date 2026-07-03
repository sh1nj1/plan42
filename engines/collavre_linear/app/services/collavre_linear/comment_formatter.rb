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
  #
  # The brackets are backslash-escaped because Linear renders comments as
  # Markdown: an unescaped "[name]: word" is a link reference definition (label +
  # destination) that Linear swallows into an empty string when the content is a
  # single token. Escaping keeps the whole line literal regardless of word count.
  module CommentFormatter
    module_function

    def outbound_body(comment)
      prefixed_body(comment.user&.display_name, comment.content.to_s)
    end

    # Prefix `content` with an escaped "[author]: " attribution, or return it
    # unchanged when `author` is blank. Single source of the prefix format so the
    # outbound Collavre->Linear body and the inbound system-comment fallback (a
    # Linear author with no matching Collavre user) stay byte-identical — the echo
    # guard above relies on the two forms matching.
    def prefixed_body(author, content)
      author.present? ? "\\[#{author}\\]: #{content}" : content
    end
  end
end
