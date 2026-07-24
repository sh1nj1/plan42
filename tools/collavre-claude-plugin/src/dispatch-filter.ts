export interface DispatchFilterInput {
  // Whether the dispatched topic is a Session-mapped topic (server flag).
  // undefined when talking to a legacy server that doesn't send it.
  sessionTopic?: boolean;
  // topic_id carried on the dispatch.
  dispatchTopicId: number;
  // This session's own session topic id (from register).
  mySessionTopicId: number | null;
}

// One shared agent fans out to many session topics, and every session
// subscribed to agent:user:<id> hears every dispatch routed to that agent. A
// session must answer:
//   - its OWN session topic (sessionTopic && id === mine), and
//   - any non-session work/project topic (server dedups concurrent handlers
//     via the atomic delegated-task claim).
// It must stay silent on a SIBLING session's mapped topic. A legacy server
// that omits the flag is treated as non-session (handle) — those servers key
// one agent per session anyway, so there is no sibling to collide with.
export function shouldHandleDispatch(input: DispatchFilterInput): boolean {
  if (input.sessionTopic && input.dispatchTopicId !== input.mySessionTopicId) {
    return false;
  }
  return true;
}
