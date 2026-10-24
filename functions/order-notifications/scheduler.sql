-- Run once during activation after enabling pg_cron and pg_net in Supabase.
-- First create Vault secret `applespace_order_notification_cron_secret` securely
-- in the Dashboard with the SAME value as Edge secret ORDER_NOTIFICATION_CRON_SECRET.
-- No token is hard-coded or printed by this script.
select cron.schedule('applespace-order-notifications','* * * * *',$job$
 select net.http_post(
  url:='https://ghmofddxpflpopwavysk.supabase.co/functions/v1/order-notifications/process',
  headers:=jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='applespace_order_notification_cron_secret')),
  body:='{}'::jsonb,timeout_milliseconds:=120000
 );
$job$);
