import { describe, it, expect, beforeAll, beforeEach } from "vitest";

// ============================================================================
// The mirror queue.
//
// What this replaced was `void mirrorX(...).catch(console.warn)` — an
// unreachable Postgres meant the event was gone, permanently, with a log line
// nobody reads. So the properties worth pinning are the ones that make loss
// impossible: an enqueued row survives, a failure comes back, a retry does not
// double-count, and a payload Postgres will never accept ends up somewhere a
// human can find rather than silently dropped.
// ============================================================================

beforeAll(() => {
  process.env.NUTRIQUEST_DB = "memory";
});

let queue: typeof import("./mirrorQueue");

beforeEach(async () => {
  queue = await import("./mirrorQueue");
  const { db } = await import("../db");
  db.exec("DELETE FROM mirror_outbox");
  db.exec("DELETE FROM mirror_outbox_dead");
});

describe("enqueue", () => {
  it("makes an event immediately due", () => {
    queue.enqueueMirror("mines_round", "round-1", { roundId: "round-1" });
    const due = queue.claimDue(10);
    expect(due).toHaveLength(1);
    expect(due[0].kind).toBe("mines_round");
    expect(due[0].idempotencyKey).toBe("round-1");
    expect(due[0].payload).toEqual({ roundId: "round-1" });
  });

  it("collapses a repeat of the same event instead of queueing it twice", () => {
    queue.enqueueMirror("mines_round", "round-1", { status: "ACTIVE" });
    queue.enqueueMirror("mines_round", "round-1", { status: "SERVED" });

    const due = queue.claimDue(10);
    expect(due).toHaveLength(1);
    // The newer state wins: a round that has since been served supersedes the
    // same round mid-flight.
    expect(due[0].payload).toEqual({ status: "SERVED" });
  });

  it("keeps the same key under different kinds apart", () => {
    queue.enqueueMirror("mines_round", "shared-id", { a: 1 });
    queue.enqueueMirror("plinko_drop", "shared-id", { b: 2 });
    expect(queue.claimDue(10)).toHaveLength(2);
  });
});

describe("delivery", () => {
  it("removes a row once it has been delivered", () => {
    queue.enqueueMirror("coin_entry", "entry-1", { amount: 10 });
    const [item] = queue.claimDue(10);
    queue.markDelivered(item.id);
    expect(queue.claimDue(10)).toHaveLength(0);
    expect(queue.queueStats().pending).toBe(0);
  });
});

describe("failure and backoff", () => {
  it("holds a failed row back rather than retrying it immediately", () => {
    queue.enqueueMirror("coin_entry", "entry-1", { amount: 10 });
    const [item] = queue.claimDue(10);

    expect(queue.markFailed(item.id, "postgres unreachable")).toBe("retry");

    // Still queued — but not due yet, which is the whole point of backoff.
    expect(queue.queueStats().pending).toBe(1);
    expect(queue.claimDue(10)).toHaveLength(0);
  });

  it("backs off exponentially, with a ceiling", () => {
    expect(queue.backoffSeconds(1)).toBe(2);
    expect(queue.backoffSeconds(2)).toBe(4);
    expect(queue.backoffSeconds(3)).toBe(8);
    // Capped, so a long outage does not schedule a retry days out.
    expect(queue.backoffSeconds(20)).toBe(1800);
  });

  it("retires a row to the dead table after the attempt ceiling, never deletes it", async () => {
    const { db } = await import("../db");
    queue.enqueueMirror("coin_entry", "doomed", { amount: 10 });

    let fate: "retry" | "dead" = "retry";
    for (let i = 0; i < queue.MAX_ATTEMPTS; i++) {
      // Make the row due again so it can be claimed on the next pass.
      db.exec("UPDATE mirror_outbox SET next_attempt_at = 0");
      const due = queue.claimDue(10);
      if (due.length === 0) break;
      fate = queue.markFailed(due[0].id, "malformed payload");
    }

    expect(fate).toBe("dead");
    const stats = queue.queueStats();
    expect(stats.pending).toBe(0);
    // Evidence, not a silent gap.
    expect(stats.dead).toBe(1);

    const dead = db
      .prepare("SELECT kind, idempotency_key, attempts, last_error FROM mirror_outbox_dead")
      .all() as unknown as {
      kind: string;
      idempotency_key: string;
      attempts: number;
      last_error: string;
    }[];
    expect(dead[0].kind).toBe("coin_entry");
    expect(dead[0].idempotency_key).toBe("doomed");
    expect(dead[0].attempts).toBe(queue.MAX_ATTEMPTS);
    expect(dead[0].last_error).toContain("malformed payload");
  });
});

describe("ordering", () => {
  it("hands back the oldest due rows first, so a backlog drains in order", () => {
    queue.enqueueMirror("gameplay_event", "first", { n: 1 });
    queue.enqueueMirror("gameplay_event", "second", { n: 2 });
    queue.enqueueMirror("gameplay_event", "third", { n: 3 });

    const due = queue.claimDue(10);
    expect(due.map((d) => d.idempotencyKey)).toEqual(["first", "second", "third"]);
  });

  it("respects the batch limit", () => {
    for (let i = 0; i < 5; i++) queue.enqueueMirror("gameplay_event", `e${i}`, { i });
    expect(queue.claimDue(2)).toHaveLength(2);
  });
});
