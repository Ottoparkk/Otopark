-- ============================================================================
-- 023  Push bildirimi: kendi tetikleyicimiz (dashboard webhook'u yerine)
-- ============================================================================

begin;

-- Supabase'in "Database Webhooks" özelliği `supabase_functions` şemasına
-- dayanır ve bu projede o şema hiç oluşturulmamış — pg_net'i açmak da onu
-- yaratmıyor. pg_net'in kendisi ise elimizde: `net.http_post` ile isteği
-- doğrudan biz atarız. Yan fayda, yapılandırmanın panel ayarlarında değil
-- migration'da durması.

create table if not exists public.push_ayar (
  id         smallint primary key default 1 check (id = 1),
  url        text not null,
  gizli      text not null,
  updated_at timestamptz not null default now()
);

alter table public.push_ayar enable row level security;

-- Politika YOK ve grant YOK: bu satırda send-push'un tek anahtarı duruyor.
-- Ona yalnızca SECURITY DEFINER tetikleyici ve SQL editörü (superuser) erişir.
revoke all on public.push_ayar from anon, authenticated;

create or replace function public.notif_push_gonder() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ayar public.push_ayar;
begin
  select * into v_ayar from public.push_ayar where id = 1;
  if not found then
    return null;   -- push yapılandırılmamış: bildirim yine de yazıldı
  end if;

  -- HATA YUTULUR, ve bu bilinçli: bu tetikleyici `bilet_kapat`, `vardiya_kapat`
  -- gibi PARA taşıyan RPC'lerin içinde ateşler. İstek atılamadığı için bir
  -- tahsilatın geri alınması, bildirimin gitmemesinden çok daha kötüdür.
  begin
    perform net.http_post(
      url     := v_ayar.url,
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-push-secret', v_ayar.gizli),
      -- `record` sarmalayıcısı Supabase webhook'unun gövdesiyle aynı, böylece
      -- ileride panel webhook'una geçilirse send-push'ta hiçbir şey değişmez.
      body    := jsonb_build_object('record', to_jsonb(new))
    );
  exception when others then
    raise warning 'push gönderilemedi: %', sqlerrm;
  end;

  return null;
end $$;

drop trigger if exists notif_push_tg on public.notifications;
create trigger notif_push_tg
  after insert on public.notifications
  for each row execute function public.notif_push_gonder();

revoke all on function public.notif_push_gonder()
  from public, anon, authenticated, service_role;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if to_regproc('net.http_post') is null then
    raise exception '023: pg_net kurulu değil (Database -> Extensions -> pg_net)';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'notif_push_tg' and not tgisinternal) then
    raise exception '023: push tetikleyicisi kurulmadı';
  end if;
  if has_table_privilege('anon', 'public.push_ayar', 'SELECT')
     or has_table_privilege('authenticated', 'public.push_ayar', 'SELECT') then
    raise exception '023: push gizli anahtarı istemciye açık';
  end if;
  if has_function_privilege('authenticated', 'public.notif_push_gonder()', 'execute') then
    raise exception '023: tetikleyici fonksiyonu istemciye açık';
  end if;
end $$;

commit;

-- ============================================================================
-- ÇALIŞTIRDIKTAN SONRA, bir kez, SQL editöründe (gizli anahtar repoda durmaz):
--
--   insert into public.push_ayar (id, url, gizli)
--   values (1,
--     'https://<project-ref>.supabase.co/functions/v1/send-push',
--     '<PUSH_SECRET>')
--   on conflict (id) do update
--     set url = excluded.url, gizli = excluded.gizli, updated_at = now();
-- ============================================================================
