-- МониТорг: новые заявки на помощь — сразу в Telegram Артёму (19.10.2026). Повторный запуск безопасен.
-- Токен бота хранится в зашифрованном хранилище базы (vault, имя tg_leads_token), номер чата — в settings (tg_leads).
-- Задаются в админке («Доступ» → «Заявки в Telegram»): rpc set_tg_leads. Отправка — net.http_post (pg_net),
-- ошибка отправки заявку не ломает: сообщение просто не уйдёт.
create extension if not exists pg_net;

create or replace function set_tg_leads(p_token text, p_chat text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  if coalesce(trim(p_token), '') <> '' then
    delete from vault.secrets where name = 'tg_leads_token';
    perform vault.create_secret(trim(p_token), 'tg_leads_token', 'Telegram: бот для заявок с сайта');
  end if;
  if p_chat is not null then
    if trim(p_chat) = '' then
      delete from settings where k = 'tg_leads';
      delete from vault.secrets where name = 'tg_leads_token';
      return false;
    end if;
    insert into settings (k, v, updated_at) values ('tg_leads', jsonb_build_object('chat', trim(p_chat)), now())
    on conflict (k) do update set v = excluded.v, updated_at = now();
  end if;
  return exists (select 1 from vault.secrets where name = 'tg_leads_token') and exists (select 1 from settings where k = 'tg_leads');
end $$;

create or replace function tg_leads_status() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  return jsonb_build_object('token', exists (select 1 from vault.secrets where name = 'tg_leads_token'),
                            'chat', (select v->>'chat' from settings where k = 'tg_leads'));
end $$;

-- отправить текст в чат заявок; возвращает false, если не настроено
create or replace function tg_leads_send(p_text text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; chat text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_leads_token';
  select v->>'chat' into chat from settings where k = 'tg_leads';
  if tok is null or chat is null then return false; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', left(p_text, 4000), 'disable_web_page_preview', true),
    headers := jsonb_build_object('Content-Type', 'application/json'));
  return true;
end $$;
revoke all on function tg_leads_send(text) from public, anon, authenticated;

create or replace function tg_leads_test() returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  return tg_leads_send('✅ МониТорг: проверка связи. Сюда будут приходить новые заявки с сайта.');
end $$;

create or replace function leads_tg() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform tg_leads_send(concat_ws(E'\n',
      '🔔 Новая заявка на МониТорге',
      'Имя: ' || new.name,
      'Телефон: ' || new.phone,
      case when coalesce(new.email, '') <> '' then 'Почта: ' || new.email end,
      case when coalesce(new.service, '') <> '' then 'Услуга: ' || new.service end,
      case when coalesce(new.lot_id, '') <> '' then 'Лот: ' || coalesce(nullif(new.lot_name, ''), new.lot_id) || E'\nhttps://monitorg.by/#/lot/' || new.lot_id
           when coalesce(new.lot, '') <> '' then 'Лот: ' || new.lot end,
      case when coalesce(new.msg, '') <> '' then 'Комментарий: ' || new.msg end,
      case when new.user_id is not null then 'Из личного кабинета' else 'С сайта, без кабинета' end,
      'Все заявки: https://monitorg.by/admin/#leads'));
  exception when others then null;   -- Telegram не ответил — заявка всё равно сохраняется
  end;
  return new;
end $$;
drop trigger if exists leads_tg on leads;
create trigger leads_tg after insert on leads for each row execute function leads_tg();

grant execute on function set_tg_leads(text, text) to anon, authenticated;
grant execute on function tg_leads_status() to anon, authenticated;
grant execute on function tg_leads_test() to anon, authenticated;
