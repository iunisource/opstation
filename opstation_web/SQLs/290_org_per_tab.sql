-- 290 — Each browser tab works in ITS OWN organization.
--
-- The active org used by RLS was stored once per login (user_active_org), so
-- every tab and device of that login shared it: switching org in one tab (or
-- on the phone) silently re-scoped all the others — menus lost modules, lists
-- came back empty, and the web app kept popping "Another tab or device
-- switched organization".
--
-- Now the web app sends the org it is showing in an "x-org-id" request header,
-- and current_user_org_id() uses it first — only if this login really is an
-- active member of that org. Requests without the header (mobile app, server
-- functions) behave exactly as before.

CREATE OR REPLACE FUNCTION public.current_user_org_id()
 RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    -- 1) The org this tab asked for (x-org-id header), if a valid membership.
    (SELECT h.org
       FROM (SELECT nullif(
                      (nullif(current_setting('request.headers', true), '')::json ->> 'x-org-id'),
                      '') AS org) h
      WHERE h.org IS NOT NULL
        AND EXISTS (SELECT 1 FROM public.users u
                     WHERE u.account_id = public.current_account_id()
                       AND u.org_id = h.org
                       AND coalesce(u.is_active, true) = true)),
    -- 2) The login's remembered active org (unchanged).
    (SELECT uao.org_id
       FROM public.user_active_org uao
      WHERE uao.account_id = public.current_account_id()
        AND EXISTS (SELECT 1 FROM public.users u
                     WHERE u.account_id = uao.account_id
                       AND u.org_id = uao.org_id)),
    -- 3) The identity's own org (single-org users).
    (SELECT org_id FROM public.users
      WHERE lower(email) = lower(auth.jwt() ->> 'email')
      LIMIT 1)
  );
$function$;
