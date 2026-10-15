// Separate reserved leading tokens from popup options without changing the goal.
export function keepGoalText(goal) {
  return /^\s*(?:@[^:\n]+:|--max\b|--(?:\s|$))/.test(goal || '') ? `-- ${goal}` : goal
}
