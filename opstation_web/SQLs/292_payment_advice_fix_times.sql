-- 292 — Payment Advice: correct approval / rejection / void times that were
-- saved 5 hours ahead (the app sent Pakistan local time without a timezone,
-- and the database read it as UTC). Run ONCE, right after deploying the fix.
update public.payment_advices set approved_at = approved_at - interval '5 hours'
 where approved_at is not null and approved_at <= now() + interval '5 hours';
update public.payment_advices set rejected_at = rejected_at - interval '5 hours'
 where rejected_at is not null and rejected_at <= now() + interval '5 hours';
update public.payment_advices set voided_at = voided_at - interval '5 hours'
 where voided_at is not null and voided_at <= now() + interval '5 hours';
