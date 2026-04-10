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

/**
 * Subscribes to a Collavre ActionCable channel for real-time comment events.
 * Implements the Rails ActionCable WebSocket protocol.
 */
export class CableSubscriber {
  private static readonly MAX_RECONNECT_ATTEMPTS = 20;
  private static readonly BASE_RECONNECT_DELAY_MS = 1_000;
  private static readonly MAX_RECONNECT_DELAY_MS = 60_000;

  private ws: WebSocket | null = null;
  private baseUrl: string;
  private token: string;
  private topicId: number;
  private callback: EventCallback;
  private channelIdentifier: string;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectAttempts = 0;
  private debug: boolean;

  constructor(
    baseUrl: string,
    token: string,
    topicId: number,
    callback: EventCallback,
    debug = false,
  ) {
    this.baseUrl = baseUrl;
    this.token = token;
    this.topicId = topicId;
    this.callback = callback;
    this.debug = debug;
    this.channelIdentifier = JSON.stringify({
      channel: "Collavre::AgentChannel",
      topic_id: topicId,
    });
  }

  connect(): void {
    const wsUrl = this.buildWsUrl();
    process.stderr.write(`[collavre-cable] Connecting to ${wsUrl.replace(/token=[^&]+/, "token=***")}\n`);
    this.ws = new WebSocket(wsUrl, ["actioncable-v1-json", "actioncable-unsupported"], {
      headers: { Origin: this.baseUrl },
    });

    this.ws.on("open", () => {
      process.stderr.write(`[collavre-cable] WebSocket OPEN\n`);
      this.reconnectAttempts = 0;
      this.subscribe();
      this.pingTimer = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.ping();
        }
      }, 30_000);
    });

    this.ws.on("message", (data: WebSocket.Data) => {
      const raw = data.toString();
      if (this.debug) {
        const parsed = JSON.parse(raw).type;
        if (parsed !== "ping") {
          process.stderr.write(`[collavre-cable] ← ${raw.slice(0, 300)}\n`);
        }
      }
      this.handleMessage(raw);
    });

    this.ws.on("close", (code: number, reason: Buffer) => {
      process.stderr.write(`[collavre-cable] WebSocket CLOSED code=${code} reason=${reason.toString()}\n`);
      this.clearTimers();
      this.scheduleReconnect();
    });

    this.ws.on("error", (err: Error) => {
      process.stderr.write(
        `[collavre-cable] WebSocket ERROR: ${err.message}\n`
      );
    });
  }

  disconnect(): void {
    this.clearTimers();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  private buildWsUrl(): string {
    const httpUrl = this.baseUrl.replace(/\/$/, "");
    const wsUrl = httpUrl.replace(/^http/, "ws");
    return `${wsUrl}/cable?token=${encodeURIComponent(this.token)}`;
  }

  private subscribe(): void {
    this.send({
      command: "subscribe",
      identifier: this.channelIdentifier,
    });
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

    // ActionCable protocol messages
    if (msg.type === "welcome" || msg.type === "ping") {
      return;
    }

    if (msg.type === "confirm_subscription") {
      process.stderr.write(
        `[collavre-plugin] Subscribed to topic ${this.topicId}\n`
      );
      return;
    }

    if (msg.type === "reject_subscription") {
      process.stderr.write(
        `[collavre-plugin] Subscription rejected for topic ${this.topicId}\n`
      );
      return;
    }

    // Data message
    if (msg.message) {
      if (msg.identifier === this.channelIdentifier) {
        process.stderr.write(`[collavre-cable] Received comment event, invoking callback\n`);
        this.callback(msg.message);
      } else if (this.debug) {
        process.stderr.write(`[collavre-cable] Identifier mismatch:\n  expected: ${this.channelIdentifier}\n  got:      ${msg.identifier}\n`);
      }
    }
  }

  private send(data: Record<string, unknown>): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;

    this.reconnectAttempts++;
    if (this.reconnectAttempts > CableSubscriber.MAX_RECONNECT_ATTEMPTS) {
      process.stderr.write(
        `[collavre-plugin] Max reconnect attempts (${CableSubscriber.MAX_RECONNECT_ATTEMPTS}) reached, giving up\n`,
      );
      return;
    }

    const delay = Math.min(
      CableSubscriber.BASE_RECONNECT_DELAY_MS * 2 ** (this.reconnectAttempts - 1),
      CableSubscriber.MAX_RECONNECT_DELAY_MS,
    );
    process.stderr.write(
      `[collavre-plugin] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}/${CableSubscriber.MAX_RECONNECT_ATTEMPTS})\n`,
    );

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private clearTimers(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }
}
