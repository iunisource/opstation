-- 369 — Label layouts (Manufacturing → Label Printing), shared by the
-- organisation. The 4 standard layouts live in the app; a row here with the
-- same id overrides one, other ids are custom layouts. Safe to run again.

create table if not exists public.label_templates (
  org_id     text not null,
  id         text not null,
  name       text not null default 'Label',
  def        jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text default (auth.uid())::text,
  primary key (org_id, id)
);

alter table public.label_templates enable row level security;

drop policy if exists label_templates_read on public.label_templates;
create policy label_templates_read on public.label_templates
  for select using (public._is_org_member(org_id) or public._is_super_admin());

drop policy if exists label_templates_write on public.label_templates;
create policy label_templates_write on public.label_templates
  for all using (public._is_org_member(org_id)) with check (public._is_org_member(org_id));

grant select, insert, update, delete on public.label_templates to authenticated;
