-- 0004_economy_fairness.sql
-- Economy and fairness (ordinary tables).
-- Source: db-documentation/03-relational-model.md (Economy and fairness).
-- Currency is integer units. keys and capsules are distinct currencies (no auto conversion).

-- app.wallets : fast-read balance; nonnegative; one row per (player, currency).
create table if not exists app.wallets (
  player_id   text not null references app.players(id) on delete cascade,
  currency    text not null check (currency in ('keys','capsules')),
  balance     bigint not null default 0 check (balance >= 0),
  version     bigint not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (player_id, currency)
);

-- app.currency_entries : append-only ledger; corrections use compensating entries.
create table if not exists app.currency_entries (
  id            uuid primary key default gen_random_uuid(),
  operation_id  uuid not null,
  entry_index   integer not null,
  player_id     text references app.players(id) on delete set null,   -- null for system account
  account       text not null default 'player' check (account in ('player','system')),
  currency      text not null,
  amount        bigint not null,          -- signed integer units
  reason        text not null,
  ref           text,
  created_at    timestamptz not null default now(),
  unique (operation_id, entry_index)
);
create index if not exists currency_entries_player_idx on app.currency_entries(player_id, created_at desc);

-- app.crate_definitions : pinned per open; validated pool/weights.
create table if not exists app.crate_definitions (
  crate_id      text not null,
  rules_version text not null,
  cost          bigint not null,
  cost_currency text not null default 'keys',
  pool          jsonb not null,           -- character pool
  rarity_weights jsonb not null,          -- seven-tier weights
  pity_policy   jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  primary key (crate_id, rules_version)
);

-- app.pity_state : scope matches the activated crate policy (no legacy global/4-tier switch).
create table if not exists app.pity_state (
  player_id   text not null references app.players(id) on delete cascade,
  pity_scope  text not null,
  counters    jsonb not null default '{}'::jsonb,
  version     bigint not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (player_id, pity_scope)
);

-- app.fairness_seeds : active seed never public; nonce allocation locked atomically.
create table if not exists app.fairness_seeds (
  id             uuid primary key default gen_random_uuid(),
  player_id      text not null references app.players(id) on delete cascade,
  commitment     text not null,           -- public hash of server seed
  server_seed_enc bytea,                  -- encrypted/private until reveal
  client_seed    text,
  next_nonce     bigint not null default 0,
  state          text not null default 'active' check (state in ('active','revealed','retired')),
  revealed_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists fairness_seeds_player_idx on app.fairness_seeds(player_id, state);

-- app.crate_opens : compact permanent verification receipt (private seed omitted from responses).
create table if not exists app.crate_opens (
  id             uuid primary key default gen_random_uuid(),
  player_id      text not null references app.players(id) on delete cascade,
  seed_id        uuid not null references app.fairness_seeds(id),
  nonce          bigint not null,
  crate_id       text not null,
  rules_version  text not null,
  roll_inputs    jsonb not null default '{}'::jsonb,
  pity_before    jsonb not null default '{}'::jsonb,
  pity_after     jsonb not null default '{}'::jsonb,
  cost           bigint not null,
  acquired_character_id uuid references app.owned_characters(id),
  commitment     text not null,
  opened_at      timestamptz not null default now(),
  unique (seed_id, nonce),
  foreign key (crate_id, rules_version) references app.crate_definitions(crate_id, rules_version)
);
create index if not exists crate_opens_player_time_idx on app.crate_opens(player_id, opened_at desc);

-- app.promo_codes / app.promo_redemptions
create table if not exists app.promo_codes (
  id           uuid primary key default gen_random_uuid(),
  code_norm    text not null unique,      -- normalized code
  code_display text not null,
  reward       jsonb not null,
  max_uses     integer,
  uses         integer not null default 0,
  expires_at   timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists app.promo_redemptions (
  code_id     uuid not null references app.promo_codes(id) on delete cascade,
  player_id   text not null references app.players(id) on delete cascade,
  redeemed_at timestamptz not null default now(),
  reward_ref  uuid,
  primary key (code_id, player_id)
);
