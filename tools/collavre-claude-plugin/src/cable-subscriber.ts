import WebSocket from "ws";

export interface CommentEvent {
  type: "comment";
  comment: {
    id: number;
    content: string;
    author_id: number;
    author_name: string;
    topic_id: number;
    creative_id: number;
    created_at: string;
  };
}

type CommentCallback = (event: CommentEvent) => void;

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
  private callback: CommentCallback;
  private channelIdentifier: string;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectAttempts = 0;

  constructor(
    baseUrl: string,
    token: string,
    topicId: number,
    callback: CommentCallback
  ) {
    this.baseUrl = baseUrl;
    this.token = token;
    this.topicId = topicId;
    this.callback = callback;
    this.channelIdentifier = JSON.stringify({
      channel: "Collavre::AgentChannel",
      topic_id: topicId,
    });
  }

  connect(): void {
    const wsUrl = this.buildWsUrl();
    this.ws = new WebSocket(wsUrl);

    this.ws.on("open", () => {
      this.reconnectAttempts = 0; // Reset on successful connection
      this.subscribe();
      // Ping every 30s to keep connection alive
      this.pingTimer = setInterval(() => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.ping();
        }
      }, 30_000);
    });

    this.ws.on("message", (data: WebSocket.Data) => {
      this.handleMessage(data.toString());
    });

    this.ws.on("close", () => {
      this.clearTimers();
      this.scheduleReconnect();
    });

    this.ws.on("error", (err: Error) => {
      process.stderr.write(
        `[collavre-plugin] WebSocket error: ${err.message}\n`
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
      message?: CommentEvent;
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
    if (msg.identifier === this.channelIdentifier && msg.message) {
      this.callback(msg.message);
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
