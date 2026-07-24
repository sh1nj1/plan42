import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface CollavreConfig {
  url: string;
  token: string;
  // Agent identity (the user-facing unit). Defaults to a single shared name so
  // that, without an explicit AGENT_NAME, every session for one human collapses
  // onto one Collavre agent (multi-session under it). Set CLAUDE_PLUGIN_OPTION_
  // agent_name to carve out a distinct agent.
  agentName: string;
  // Explicit session id override (CLAUDE_PLUGIN_OPTION_session_id). When unset,
  // the session id is derived+persisted per cwd (see session.ts).
  sessionIdOverride?: string;
}

export const DEFAULT_AGENT_NAME = "claude";

type Env = Record<string, string | undefined>;

const CONFIG_PATH = join(homedir(), ".config", "collavre", "config.json");

// Resolve the agent name (Agent = the user-visible unit). Explicit option wins;
// otherwise the default singleton so Claude is "just one agent" per human.
export function resolveAgentName(env: Env): string {
  const explicit = env.CLAUDE_PLUGIN_OPTION_agent_name?.trim();
  return explicit || DEFAULT_AGENT_NAME;
}

// Resolve an explicit session-id override, if the operator pinned one. Blank ->
// undefined so the caller falls through to cwd-derived persistence.
export function resolveSessionIdOverride(env: Env): string | undefined {
  const explicit = env.CLAUDE_PLUGIN_OPTION_session_id?.trim();
  return explicit || undefined;
}

export function loadConfig(env: Env = process.env): CollavreConfig {
  const agentName = resolveAgentName(env);
  const sessionIdOverride = resolveSessionIdOverride(env);

  // Prefer environment variables from Claude Plugin system
  const envUrl = env.CLAUDE_PLUGIN_OPTION_url;
  const envToken = env.CLAUDE_PLUGIN_OPTION_token;

  if (envUrl && envToken) {
    return { url: envUrl, token: envToken, agentName, sessionIdOverride };
  }

  // Fallback to config file for standalone / mcp-add usage
  try {
    const raw = readFileSync(CONFIG_PATH, "utf-8");
    const fileConfig = JSON.parse(raw) as Partial<CollavreConfig>;
    if (fileConfig.url && fileConfig.token) {
      // A file-provided agent_name/session_id is honored, but an explicit env
      // option still takes precedence (already folded into the defaults above).
      const fileAgentName = fileConfig.agentName?.trim();
      const fileSessionId = fileConfig.sessionIdOverride?.trim();
      return {
        url: fileConfig.url,
        token: fileConfig.token,
        agentName: env.CLAUDE_PLUGIN_OPTION_agent_name?.trim()
          ? agentName
          : fileAgentName || agentName,
        sessionIdOverride: sessionIdOverride ?? (fileSessionId || undefined),
      };
    }
  } catch {
    // Config file not found or unreadable
  }

  throw new Error(
    "Collavre config not found. Install as a Claude plugin (claude plugin install), " +
    `or create ${CONFIG_PATH} with url and token fields.`
  );
}
