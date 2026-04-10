import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface CollavreConfig {
  url: string;
  token: string;
}

const CONFIG_PATH = join(homedir(), ".config", "collavre", "config.json");

export function loadConfig(): CollavreConfig {
  // Prefer environment variables from Claude Plugin system
  const envUrl = process.env.CLAUDE_PLUGIN_OPTION_url;
  const envToken = process.env.CLAUDE_PLUGIN_OPTION_token;

  if (envUrl && envToken) {
    return { url: envUrl, token: envToken };
  }

  // Fallback to config file for standalone / mcp-add usage
  try {
    const raw = readFileSync(CONFIG_PATH, "utf-8");
    const config = JSON.parse(raw) as CollavreConfig;
    if (config.url && config.token) {
      return config;
    }
  } catch {
    // Config file not found or unreadable
  }

  throw new Error(
    "Collavre config not found. Install as a Claude plugin (claude plugin install), " +
    `or create ${CONFIG_PATH} with url and token fields.`
  );
}
