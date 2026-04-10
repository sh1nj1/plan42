import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface CollavreConfig {
  url: string;
  token: string;
}

const CONFIG_PATH = join(homedir(), ".config", "collavre", "config.json");

export function loadConfig(): CollavreConfig {
  const raw = readFileSync(CONFIG_PATH, "utf-8");
  const config = JSON.parse(raw) as CollavreConfig;

  if (!config.url || !config.token) {
    throw new Error(
      `Invalid config at ${CONFIG_PATH}: url and token are required`
    );
  }

  return config;
}
