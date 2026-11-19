-- Run once in Supabase > SQL Editor.
-- When an appointment becomes 'Completed', push it to the ML service so the model
-- learns from it immediately. The service ALSO polls Supabase every few minutes,
-- so a dropped webhook (e.g. the service was waking up) is never a lost sample.

-- STEP 1 (run SEPARATELY, once): store the secret that Render generated for WEBHOOK_SECRET.
--   select vault.create_secret('PASTE_WEBHOOK_SECRET_FROM_RENDER', 'ml_webhook_secret');
--
-- STEP 2: edit v_url below to your Render URL, then run everything underneath.

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_ml_service()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text := 'https://YOUR-SERVICE.onrender.com/train';   -- <== EDIT
  v_secret text;
  v_dob    date;
  v_age    int;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'ml_webhook_secret' limit 1;

  select p.date_of_birth into v_dob from patients p where p.id = new.patient_id;
  if v_dob is not null then
    v_age := extract(year from age(coalesce(new.consultation_start, now())::date, v_dob));
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Webhook-Secret', coalesce(v_secret, '')),
    body    := jsonb_build_object(
                 'appointment_id',     new.id::text,
                 'symptom',            new.initial_symptom,
                 'queue_serial',       new.queue_serial,
                 'age',                v_age,
                 'consultation_start', new.consultation_start,
                 'consultation_end',   new.consultation_end),
    timeout_milliseconds := 10000
  );
  return new;
exception when others then
  -- Never block the doctor's "complete" action because of an ML hiccup.
  raise warning 'notify_ml_service failed: %', sqlerrm;
  return new;
end;
$$;

drop trigger if exists trg_notify_ml_service on public.appointments;
create trigger trg_notify_ml_service
after update of status on public.appointments
for each row
when (new.status = 'Completed'
      and old.status is distinct from 'Completed'
      and new.consultation_start is not null
      and new.consultation_end   is not null)
execute function public.notify_ml_service();
