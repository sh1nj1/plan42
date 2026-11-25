module Collavre
  # Human-facing text for an MCP tool: a one-line summary for lists and the
  # slash-command menu, plus longer details revealed behind "more".
  #
  # The tool_description declared on the service stays English and is written
  # for the LLM. People read the localized copy under
  # collavre.tool_descriptions.<tool_name>; engines add keys for their own
  # tools. Tools without translations (user-defined Ruby tools) fall back to
  # splitting their declared description: the first sentence is the summary.
  module ToolDescription
    SENTENCE_END = /(?<=[.!?。])\s+/

    module_function

    def for(name, description)
      key = name.to_s
      localized = key.match?(/\A\w+\z/) && I18n.t("collavre.tool_descriptions.#{key}", default: nil)
      return localized_parts(localized) if localized.is_a?(Hash) && localized[:summary].present?

      split(description)
    end

    def localized_parts(localized)
      { summary: localized[:summary].to_s, details: localized[:details].presence&.to_s }
    end

    def split(description)
      text = description.to_s.strip
      first_paragraph, rest = text.split(/\n\s*\n/, 2)
      summary, more = first_paragraph.to_s.squish.split(SENTENCE_END, 2)
      details = [ more, rest&.strip ].compact_blank.join("\n\n")
      { summary: summary.to_s, details: details.presence }
    end
  end
end
