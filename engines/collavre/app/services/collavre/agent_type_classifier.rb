module Collavre
  # Classifies an AI user/agent into a coarse role type by scanning its
  # system prompt. Shared by the orchestration and system-events context
  # builders so the prompt-to-type mapping lives in exactly one place.
  module AgentTypeClassifier
    module_function

    # Returns the agent type string ("developer", "pm", "qa", "researcher",
    # "marketer", "planner") or "agent" as the default when nothing matches.
    def classify(user)
      prompt = user.effective_system_prompt.to_s.downcase
      case prompt
      when /developer|개발/ then "developer"
      when /pm|project.?manager|프로젝트/ then "pm"
      when /qa|test|quality|테스트|품질/ then "qa"
      when /research|조사|연구/ then "researcher"
      when /market|마케팅/ then "marketer"
      when /plan|기획/ then "planner"
      else "agent"
      end
    end
  end
end
