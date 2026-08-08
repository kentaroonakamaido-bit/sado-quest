-- ============================================================
-- たびクエスト｜これ1本だけ流せば準備完了
--
--   ・佐渡だけの地図 → 日本ぜんぶの地図 に引っ越します
--   ・投稿画面のログイン／合言葉をなくします
--
-- 何度実行しても壊れません。
-- 実行するところ：Supabase ダッシュボード → SQL Editor → 貼りつけて Run
--
-- 作成：2026年8月8日
-- ============================================================


-- ============================================================
-- 第1部　佐渡だけ → 日本ぜんぶ
--
--   これまで：旅行1件（佐渡クエスト）＝ 共有URL1本
--   これから：マップ1つ（＝共有URL1本）の下に、旅行を何件でもぶら下げる
--
--   家族に配ったURLは変わりません。佐渡は「旅行その1」として残ります。
-- ============================================================

-- ------------------------------------------------------------
-- 1-1. マップ（maps）テーブル
--      家族に配る共有URLの合言葉は、これ以降ここが持ちます。
--      旅行が何件増えても、家族が見るURLは1本のままです。
-- ------------------------------------------------------------
create table if not exists public.maps (
  id           uuid primary key default gen_random_uuid(),
  title        text        not null default 'たびクエスト',
  subtitle     text,
  share_token  text        not null unique,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

drop trigger if exists maps_touch on public.maps;
create trigger maps_touch
  before update on public.maps
  for each row execute function public.touch_updated_at();


-- ------------------------------------------------------------
-- 1-2. 旅行（trips）を、マップにぶら下げられるようにする
-- ------------------------------------------------------------

-- どのマップに属する旅行か
alter table public.trips
  add column if not exists map_id uuid references public.maps(id) on delete cascade;

-- 「どのへんの旅行か」を人の言葉で（例：新潟県・佐渡島）
alter table public.trips
  add column if not exists area_name text;

-- 旅行を新しく作るとき、合言葉を毎回考えなくていいように自動生成にする
alter table public.trips
  alter column share_token set default encode(gen_random_bytes(16), 'hex');

create index if not exists trips_map_started_idx
  on public.trips (map_id, started_at);


-- ------------------------------------------------------------
-- 1-3. 引っ越し本番
--      いまある共有トークンを、そのままマップに引き継ぎます。
--      → 家族に送ったURLはそのまま使えます。
-- ------------------------------------------------------------

-- (a) 既存の旅行がある場合：いちばん古い旅行のトークンをマップが受け継ぐ
insert into public.maps (title, subtitle, share_token)
select 'たびクエスト', 'かぞくの冒険マップ', t.share_token
from public.trips t
where not exists (select 1 from public.maps)
order by t.created_at asc
limit 1;

-- (b) 旅行が1件もない場合：新しくトークンを作る
insert into public.maps (title, subtitle, share_token)
select 'たびクエスト', 'かぞくの冒険マップ', encode(gen_random_bytes(16), 'hex')
where not exists (select 1 from public.maps);

-- (c) まだマップに属していない旅行を、全部そのマップにぶら下げる
update public.trips
   set map_id = (select id from public.maps order by created_at asc limit 1)
 where map_id is null;

-- (d) 佐渡の旅行に地域名を入れておく（すでに入っていれば触らない）
update public.trips
   set area_name = '新潟県・佐渡島'
 where area_name is null
   and title like '%佐渡%';


-- ============================================================
-- 1-4. 家族向けの「窓口」（合言葉を知っている人だけに答える関数）
--
--      get_map        … マップの名前
--      get_trips      … 旅行の一覧（日本地図に置くピン用）
--      get_trip_posts … 選んだ旅行の投稿（旅行の詳細地図用）
--
--      合言葉が違えば、どれも「空っぽ」を返すだけです。
-- ============================================================

-- ---- マップの情報 ----
create or replace function public.get_map(p_token text)
returns table(id uuid, title text, subtitle text)
language sql
stable
security definer
set search_path = public
as $fn$
  select m.id, m.title, m.subtitle
  from public.maps m
  where m.share_token = p_token
  limit 1;
$fn$;


-- ---- 旅行の一覧（1行＝1旅行。日本地図のピンになります） ----
create or replace function public.get_trips(p_token text)
returns table(
  id          uuid,
  title       text,
  subtitle    text,
  area_name   text,
  status      text,
  started_at  timestamptz,
  ended_at    timestamptz,
  post_count  bigint,
  center_lat  numeric,
  center_lng  numeric,
  cover_url   text,
  first_at    timestamptz,
  last_at     timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    t.id,
    t.title,
    t.subtitle,
    t.area_name,
    t.status,
    t.started_at,
    t.ended_at,
    count(p.id)                       as post_count,
    round(avg(p.latitude),  6)        as center_lat,
    round(avg(p.longitude), 6)        as center_lng,
    (select coalesce(p2.thumbnail_url, p2.image_url)
       from public.posts p2
      where p2.trip_id = t.id
        and p2.is_published = true
      order by p2.sequence_number asc
      limit 1)                        as cover_url,
    min(p.posted_at)                  as first_at,
    max(p.posted_at)                  as last_at
  from public.trips t
  join public.maps  m on m.id = t.map_id
  left join public.posts p
         on p.trip_id = t.id
        and p.is_published = true
  where m.share_token = p_token
  group by t.id, t.title, t.subtitle, t.area_name, t.status,
           t.started_at, t.ended_at, t.created_at
  order by coalesce(t.started_at, t.created_at) asc;
$fn$;


-- ---- 選んだ旅行の投稿 ----
create or replace function public.get_trip_posts(p_token text, p_trip_id uuid)
returns table(
  id uuid, sequence_number integer, image_url text, thumbnail_url text,
  comment text, place_name text, latitude numeric, longitude numeric,
  posted_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  select p.id, p.sequence_number, p.image_url, p.thumbnail_url,
         p.comment, p.place_name, p.latitude, p.longitude, p.posted_at
  from public.posts p
  join public.trips t on t.id = p.trip_id
  join public.maps  m on m.id = t.map_id
  where m.share_token = p_token
    and p.trip_id     = p_trip_id
    and p.is_published = true
  order by p.sequence_number asc;
$fn$;


-- 呼び出せる相手を絞る
revoke all on function public.get_map(text)              from public;
revoke all on function public.get_trips(text)            from public;
revoke all on function public.get_trip_posts(text, uuid) from public;

grant execute on function public.get_map(text)              to anon, authenticated;
grant execute on function public.get_trips(text)            to anon, authenticated;
grant execute on function public.get_trip_posts(text, uuid) to anon, authenticated;

-- 旧方式（get_trip / get_posts）も残してあります。
-- 家族の端末に古い画面がキャッシュされていても、そのまま佐渡が見えます。


-- ============================================================
-- 第2部　投稿画面のログイン／合言葉をなくす
--
--   投稿画面（admin.html）を開いたら、そのまま投稿できるようにします。
--   ログインも、合言葉の入力も要りません。
--
--   【ご承知おきください】
--   この設定にすると、admin.html のURLを知っている人なら誰でも
--   投稿・修正・削除ができます。家族用の割り切った設定です。
--   （家族が見る index.html のほうは、これまでどおり ?t= の合言葉が要ります）
--
--   もし後で元に戻したくなったら、このファイルの第2部の
--   create policy を全部 drop policy に読み替えて流せば閉じられます。
-- ============================================================

-- ------------------------------------------------------------
-- 2-1. マップ・旅行・投稿を、誰でも読み書きできるようにする
-- ------------------------------------------------------------

alter table public.maps  enable row level security;
alter table public.trips enable row level security;
alter table public.posts enable row level security;

-- マップ（共有URLの取り出しに使います）
drop policy if exists maps_open on public.maps;
create policy maps_open
  on public.maps for all
  to anon, authenticated
  using (true)
  with check (true);

-- 旅行
drop policy if exists trips_open on public.trips;
create policy trips_open
  on public.trips for all
  to anon, authenticated
  using (true)
  with check (true);

-- 投稿
drop policy if exists posts_open on public.posts;
create policy posts_open
  on public.posts for all
  to anon, authenticated
  using (true)
  with check (true);

-- テーブルそのものを触る権限（RLSとは別に、これも要ります）
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete
  on public.maps, public.trips, public.posts
  to anon, authenticated;


-- ------------------------------------------------------------
-- 2-2. 写真の保存先を、誰でも置けるようにする
--      （これで Edge Function は要らなくなります）
-- ------------------------------------------------------------

-- バケットが無ければ作る（公開＝家族が写真を見られるように）
insert into storage.buckets (id, name, public)
select 'photos', 'photos', true
where not exists (select 1 from storage.buckets where id = 'photos');

update storage.buckets set public = true where id = 'photos';

-- 読むのは誰でもOK（家族が見るため）
drop policy if exists storage_public_read on storage.objects;
create policy storage_public_read
  on storage.objects for select
  to anon, authenticated
  using (bucket_id in ('photos', 'site'));

-- 置く・直す・消すも誰でもOK（お父さんがログインせずに投稿するため）
drop policy if exists storage_open_insert on storage.objects;
create policy storage_open_insert
  on storage.objects for insert
  to anon, authenticated
  with check (bucket_id = 'photos');

drop policy if exists storage_open_update on storage.objects;
create policy storage_open_update
  on storage.objects for update
  to anon, authenticated
  using (bucket_id = 'photos')
  with check (bucket_id = 'photos');

drop policy if exists storage_open_delete on storage.objects;
create policy storage_open_delete
  on storage.objects for delete
  to anon, authenticated
  using (bucket_id = 'photos');

-- 古い「ログインした人だけ」のルールは、もう使わないので外す
drop policy if exists storage_admin_insert on storage.objects;
drop policy if exists storage_admin_update on storage.objects;
drop policy if exists storage_admin_delete on storage.objects;


-- ============================================================
-- 第3部　確認
--   下に出てくるURLを家族に送ってください。
-- ============================================================
select
  m.title                                      as "マップ名",
  count(t.id)                                  as "旅行の数",
  'https://kentaroonakamaido-bit.github.io/sado-quest/index.html?t='
    || m.share_token                           as "家族に送るURL",
  'https://kentaroonakamaido-bit.github.io/sado-quest/admin.html'
                                               as "お父さんの投稿URL"
from public.maps m
left join public.trips t on t.map_id = m.id
group by m.id, m.title, m.share_token;
