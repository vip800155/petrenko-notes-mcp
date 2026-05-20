-- petrenko-notes-mcp / schema.sql
--
-- Postgres schema for the personal knowledge notes layer.
-- Designed for Supabase (Postgres 15+) but works on any Postgres
-- with pgvector and pg_trgm extensions available.

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------

create extension if not exists vector;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- Text search configuration
-- ---------------------------------------------------------------------------
-- A custom configuration that handles mixed-language content (English + other
-- languages in the same note). Falls back to a simple unaccented dictionary
-- so Cyrillic, Latin, and numeric tokens all index cleanly.
--
-- If 'public.msg_search' already exists in your project, this block is a no-op.

do $$
begin
  if not exists (
    select 1 from pg_ts_config where cfgname = 'msg_search'
  ) then
    create text search configuration public.msg_search ( copy = simple );
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Main table
-- ---------------------------------------------------------------------------

create table if not exists petrenko_notes (
  id           uuid primary key default gen_random_uuid(),
  topic        text not null,
  content      text not null,
  type         text not null
                 check (type in (
                   'decision','insight','idea','task','journal',
                   'to_study','contact_note','question'
                 )),
  status       text not null default 'new'
                 check (status in ('new','in_progress','done','cancelled')),
  project      text not null,
  source       text not null default 'claude_chat',
  author       text,
  volatility   text default 'stable' check (volatility in ('stable','volatile')),
  related_ids  uuid[] default '{}',
  embedding    vector(1536),
  fts          tsvector generated always as (
                  to_tsvector(
                    'public.msg_search',
                    coalesce(topic, '') || ' ' || coalesce(content, '')
                  )
                ) stored,
  valid_from   timestamptz not null default now(),
  valid_to     timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table  petrenko_notes is 'Personal knowledge notes with hybrid search (ILIKE + FTS + vector).';
comment on column petrenko_notes.embedding   is 'OpenAI text-embedding-3-small, 1536-dim. Filled async after insert.';
comment on column petrenko_notes.fts         is 'Generated tsvector over topic || content, used for FTS channel.';
comment on column petrenko_notes.valid_from  is 'Append-only history start. Updates create new rows linked by id.';
comment on column petrenko_notes.valid_to    is 'Null means current row. Non-null means superseded.';
comment on column petrenko_notes.volatility  is 'stable = unlikely to change; volatile = expected to change frequently.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Vector channel: HNSW for cosine similarity on the embedding column.
create index if not exists idx_pn_embedding
  on petrenko_notes using hnsw (embedding vector_cosine_ops);

-- FTS channel: GIN on the generated tsvector column.
create index if not exists idx_pn_fts
  on petrenko_notes using gin (fts);

-- ILIKE channel: GIN trigram index on the concatenated topic + content.
create index if not exists idx_pn_trgm
  on petrenko_notes using gin ((topic || ' ' || content) gin_trgm_ops);

-- Filter indexes used by the RPC's filter clauses.
create index if not exists idx_pn_type      on petrenko_notes (type);
create index if not exists idx_pn_status    on petrenko_notes (status);
create index if not exists idx_pn_project   on petrenko_notes (project);
create index if not exists idx_pn_created   on petrenko_notes (created_at desc);

-- ---------------------------------------------------------------------------
-- Trigger to keep updated_at fresh
-- ---------------------------------------------------------------------------

create or replace function pn_set_updated_at()
returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists pn_set_updated_at on petrenko_notes;
create trigger pn_set_updated_at
  before update on petrenko_notes
  for each row execute function pn_set_updated_at();
