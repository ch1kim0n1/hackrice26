// ensurePlayer — mirror the SQLite "auto-create player on first write" behavior
// (feat/db-alignment triggers) for TigerData. Runtime player ids come from the
// X-Player-Id header and won't exist in app.players until first mirrored write,
// so every mirror upserts a minimal guest player first to satisfy foreign keys.
import { PoolClient } from "pg";

export async function ensurePlayer(
  client: PoolClient,
  playerId: string,
  displayName?: string
): Promise<void> {
  await client.query(
    `insert into app.players (id, display_name, kind)
     values ($1, $2, 'guest')
     on conflict (id) do nothing`,
    [playerId, displayName ?? `Trainer ${playerId.slice(0, 8)}`]
  );
}
