import WebSocket from "ws";

export interface AgentEvent {
  type: "dispatch" | "comment";
  agent_id?: number;
  comment: {
    id: number;
    content: string;
    author_id: number;
    author_name: string;
    topic_id: number;
    creative_id: number;
    created_at?: string;
  };
}

type EventCallback = (event: AgentEvent) => void;

export class CableSubscriber {
  private static readonly BASE_RECONNECT_DELAY_MS = 1_000;
  private static readonly MAX_RECONNECT_DELAY_MS = 60_000;
  private static readonly WELCOME_TIMEOUT_MS = 10_000;
  // ActionCable pings every ~3s; 15s idle means the link is dead.
  private static readonly STALE_THRESHOLD_MS = 15_000;
  private static readonly STALE_CHECK_INTERVAL_MS = 5_000;

  private ws: WebSocket | null = null;
  private baseUrl: string;
  private token: string;
  private topicId: number | null = null;
  private callback: EventCallback;
  private channelIdentifier: string | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private staleCheckTimer: ReturnType<typeof setInterval> | null = null;
  private welcomeTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempts = 0;
  private debug: boolean;
  private welcomeResolve: (() => void) | null = null;
  private welcomeReject: ((err: Error) => void) | null = null;
  private lastMessageAt = 0;
  private stopped = false;

  constructor(
    baseUrl: string,
    token: string,
    callback: EventCallback,
    debug = false,
  ) {
    this.baseUrl = baseUrl;
    this.token = token;
    this.callback = callback;
    this.debug = debug;
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.welcomeResolve = resolve;
      this.welcomeReject = reject;
      this.welcomeTimer = setTimeout(() => {
        const r = this.welcomeReject;
        this.clearWelcomeWaiters();
        if (r) {
          r(
            new Error(
              `ActionCable welcome not received within ${CableSubscriber.WELCOME_TIMEOUT_MS}ms`,
            ),
          );
        }
      }, CableSubscriber.WELCOME_TIMEOUT_MS);
      this.openSocket();
    });
  }

  subscribeTo(topicId: number): void {
    this.topicId = topicId;
    this.channelIdentifier = JSON.stringify({
      channel: "Collavre::AgentChannel",
      topic_id: topicId,
    });
    this.sendSubscribe();
  }

  disconnect(): void {
    this.stopped = true;
    this.clearTimers();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  private openSocket(): void {
    const wsUrl = this.buildWsUrl();
    process.stderr.write(
      `[collavre-cable] Connecting to ${wsUrl.replace(/token=[^&]+/, "token=***")}\n`,
    );
    this.ws = new WebSocket(
      wsUrl,
      ["actioncable-v1-json", "actioncable-unsupported"],
      { headers: { Origin: this.baseUrl } },
    );

    this.ws.on("open", () => {
      process.stderr.write(`[collavre-cable] WebSocket OPEN\n`);
      this.reconnectAttempts = 0;
      this.lastMessageAt = Date.now();
      this.startStaleCheck();
    });

    this.ws.on("message", (data: WebSocket.Data) => {
      this.lastMessageAt = Date.now();
      const raw = data.toString();
      if (this.debug) {
        try {
          const parsed = JSON.parse(raw);
          if (parsed.type !== "ping") {
            process.stderr.write(`[collavre-cable] ← ${raw.slice(0, 300)}\n`);
          }
        } catch {
          process.stderr.write(
            `[collavre-cable] ← (unparseable) ${raw.slice(0, 300)}\n`,
          );
        }
      }
      this.handleMessage(raw);
    });

    this.ws.on("close", (code: number, reason: Buffer) => {
      process.stderr.write(
        `[collavre-cable] WebSocket CLOSED code=${code} reason=${reason.toString()}\n`,
      );
      this.stopStaleCheck();
      if (!this.stopped) this.scheduleReconnect();
    });

    this.ws.on("error", (err: Error) => {
      process.stderr.write(`[collavre-cable] WebSocket ERROR: ${err.message}\n`);
      const reject = this.welcomeReject;
      if (reject) {
        this.clearWelcomeWaiters();
        reject(err);
      }
    });
  }

  private startStaleCheck(): void {
    this.stopStaleCheck();
    this.staleCheckTimer = setInterval(() => {
      const idleMs = Date.now() - this.lastMessageAt;
      if (idleMs > CableSubscriber.STALE_THRESHOLD_MS) {
        process.stderr.write(
          `[collavre-cable] Stale connection (${idleMs}ms idle), forcing reconnect\n`,
        );
        this.ws?.terminate();
      }
    }, CableSubscriber.STALE_CHECK_INTERVAL_MS);
  }

  private stopStaleCheck(): void {
    if (this.staleCheckTimer) {
      clearInterval(this.staleCheckTimer);
      this.staleCheckTimer = null;
    }
  }

  private buildWsUrl(): string {
    const httpUrl = this.baseUrl.replace(/\/$/, "");
    const wsUrl = httpUrl.replace(/^http/, "ws");
    return `${wsUrl}/cable?token=${encodeURIComponent(this.token)}`;
  }

  private sendSubscribe(): void {
    if (this.channelIdentifier) {
      this.send({
        command: "subscribe",
        identifier: this.channelIdentifier,
      });
    }
  }

  private handleMessage(raw: string): void {
    let msg: {
      type?: string;
      identifier?: string;
      message?: AgentEvent;
    };

    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (msg.type === "welcome") {
      const resolve = this.welcomeResolve;
      this.clearWelcomeWaiters();
      if (resolve) resolve();
      if (this.channelIdentifier) {
        this.sendSubscribe();
      }
      return;
    }

    if (msg.type === "ping") return;

    if (msg.type === "confirm_subscription") {
      process.stderr.write(
        `[collavre-cable] Subscribed to topic ${this.topicId}\n`,
      );
      return;
    }

    if (msg.type === "reject_subscription") {
      process.stderr.write(
        `[collavre-cable] Subscription rejected for topic ${this.topicId}\n`,
      );
      return;
    }

    if (msg.message) {
      if (msg.identifier === this.channelIdentifier) {
        process.stderr.write(
          `[collavre-cable] Received event, invoking callback\n`,
        );
        this.callback(msg.message);
      } else if (this.debug) {
        process.stderr.write(
          `[collavre-cable] Identifier mismatch:\n  expected: ${this.channelIdentifier}\n  got:      ${msg.identifier}\n`,
        );
      }
    }
  }

  private send(data: Record<string, unknown>): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer || this.stopped) return;

    this.reconnectAttempts++;
    const delay = Math.min(
      CableSubscriber.BASE_RECONNECT_DELAY_MS *
        2 ** (this.reconnectAttempts - 1),
      CableSubscriber.MAX_RECONNECT_DELAY_MS,
    );
    process.stderr.write(
      `[collavre-cable] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})\n`,
    );

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      // Fire-and-forget: reconnect has no Promise to await. Errors will
      // surface via the 'error' / 'close' handlers and trigger another
      // scheduleReconnect.
      this.openSocket();
    }, delay);
  }

  private clearWelcomeWaiters(): void {
    this.welcomeResolve = null;
    this.welcomeReject = null;
    if (this.welcomeTimer) {
      clearTimeout(this.welcomeTimer);
      this.welcomeTimer = null;
    }
  }

  private clearTimers(): void {
    this.stopStaleCheck();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.clearWelcomeWaiters();
  }
}
