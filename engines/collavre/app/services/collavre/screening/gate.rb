# frozen_string_literal: true

module Collavre
  module Screening
    # Asks every resolved screener about the turn's texts and returns the
    # strictest Verdict. A failure is an "error" verdict, never a pass. Each
    # screener's answer is audited on the task; nothing is cached.
    class Gate
      def call(texts, agent:, creative:, task:)
        chunks = Input.chunks(texts)
        return Verdict.new(verdict: "passed", screener_id: "none") if chunks.empty?

        Current.set(screening: true) do
          verdicts = ScreenerResolver.for(agent: agent, creative: creative, task: task)
                                     .map { |screener| scan(screener, chunks) }
          record!(task, verdicts, Screening.digest(texts))
          Verdict.strictest(verdicts)
        end
      end

      private

      def scan(screener, chunks)
        Verdict.strictest(chunks.map { |chunk| Verdict.from(screener.judge(chunk), screener) })
      rescue StandardError => e
        Rails.logger.warn("[Screening] #{screener.id} failed: #{e.class}")
        Verdict.error(screener, e)
      end

      def record!(task, verdicts, digest)
        verdicts.each do |verdict|
          task.task_actions.create!(action_type: ACTION_TYPE, status: "done",
            payload: verdict.to_h.merge("policy_version" => POLICY_VERSION, "content_digest" => digest))
        end
      end
    end
  end
end
