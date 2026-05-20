-- petrenko-notes-mcp / rpc_search_notes.sql
--
-- Hybrid 3-channel search with Reciprocal Rank Fusion (RRF).
--
-- Channels:
--   ILIKE (pg_trgm GIN)  weight 2.0  - exact and partial string match
--   FTS   (tsvector GIN) weight 1.0  - tokenised full-text search
--   Vector (HNSW)        weight 1.0  - semantic cosine similarity
--
-- Fusion:
--   score(doc) = SUM_over_channels( weight / (k + rank_in_channel) )
--   k = 60 (RRF default)
--
-- A document that appears in multiple channels ranks higher than one that
-- appears in only one. ILIKE carries the highest weight because exact
-- matches are almost always what the user asked for.

create or replace function public.search_notes(
  query_text       text,
  query_embedding  vector(1536),
  match_count      int     default 10,
  type_filter      text    default null,
  status_filter    text    default null,
  project_filter   text    default null
)
returns table (
  id          uuid,
  topic       text,
  content     text,
  type        text,
  status      text,
  project     text,
  created_at  timestamptz,
  similarity  float,
  rrf_score   float
)
language sql
stable
as $$
with
-- Channel 1: ILIKE via pg_trgm. Returns rank by trigram similarity.
ilike_rank as (
  select
    n.id,
    row_number() over (
      order by similarity(n.topic || ' ' || n.content, query_text) desc
    ) as r
  from petrenko_notes n
  where
    (n.topic || ' ' || n.content) % query_text
    and (type_filter    is null or n.type    = type_filter)
    and (status_filter  is null or n.status  = status_filter)
    and (project_filter is null or n.project = project_filter)
  limit 50
),
-- Channel 2: FTS via the generated tsvector and msg_search configuration.
fts_rank as (
  select
    n.id,
    row_number() over (
      order by ts_rank(n.fts, plainto_tsquery('public.msg_search', query_text)) desc
    ) as r
  from petrenko_notes n
  where
    n.fts @@ plainto_tsquery('public.msg_search', query_text)
    and (type_filter    is null or n.type    = type_filter)
    and (status_filter  is null or n.status  = status_filter)
    and (project_filter is null or n.project = project_filter)
  limit 50
),
-- Channel 3: vector cosine distance via HNSW.
vec_rank as (
  select
    n.id,
    row_number() over (
      order by n.embedding <=> query_embedding
    ) as r
  from petrenko_notes n
  where
    n.embedding is not null
    and (type_filter    is null or n.type    = type_filter)
    and (status_filter  is null or n.status  = status_filter)
    and (project_filter is null or n.project = project_filter)
  limit 50
),
-- Fuse rankings with weighted RRF. k = 60.
fused as (
  select
    n.id,
    coalesce(2.0 / (60 + i.r), 0)
      + coalesce(1.0 / (60 + f.r), 0)
      + coalesce(1.0 / (60 + v.r), 0)
    as rrf_score
  from petrenko_notes n
    left join ilike_rank i on i.id = n.id
    left join fts_rank   f on f.id = n.id
    left join vec_rank   v on v.id = n.id
  where i.id is not null or f.id is not null or v.id is not null
)
select
  n.id,
  n.topic,
  n.content,
  n.type,
  n.status,
  n.project,
  n.created_at,
  case
    when n.embedding is not null then 1 - (n.embedding <=> query_embedding)
    else null
  end as similarity,
  fused.rrf_score
from fused
  join petrenko_notes n on n.id = fused.id
order by fused.rrf_score desc
limit match_count;
$$;

comment on function public.search_notes(
  text, vector, int, text, text, text
) is
  '3-channel hybrid search with RRF fusion. See sql/rpc_search_notes.sql for details.';
