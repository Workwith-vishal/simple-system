GRANT USAGE ON SCHEMA public TO authenticated, service_role;

CREATE TYPE public.app_role AS ENUM ('admin', 'member');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL,
  department text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_department_check CHECK (
    department IS NULL OR department IN ('Developer', 'Designer', 'Backend Developer', 'HR')
  )
);
GRANT SELECT ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  assignee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  assigned_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  deadline date,
  priority text NOT NULL DEFAULT 'normal',
  status text NOT NULL DEFAULT 'assigned',
  progress_note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tasks_priority_check CHECK (priority IN ('low', 'normal', 'high')),
  CONSTRAINT tasks_status_check CHECK (status IN ('assigned', 'in_progress', 'completed'))
);
GRANT SELECT, INSERT ON public.tasks TO authenticated;
GRANT UPDATE (status, progress_note) ON public.tasks TO authenticated;
GRANT ALL ON public.tasks TO service_role;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.eod_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  report_date date NOT NULL DEFAULT CURRENT_DATE,
  completed_work text NOT NULL,
  in_progress text NOT NULL DEFAULT '',
  blockers text NOT NULL DEFAULT '',
  tomorrow_plan text NOT NULL DEFAULT '',
  additional_notes text NOT NULL DEFAULT '',
  submitted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT eod_reports_one_per_user_per_day UNIQUE (user_id, report_date),
  CONSTRAINT eod_reports_completed_work_check CHECK (length(trim(completed_work)) > 0)
);
GRANT SELECT, INSERT ON public.eod_reports TO authenticated;
GRANT UPDATE (completed_work, in_progress, blockers, tomorrow_plan, additional_notes) ON public.eod_reports TO authenticated;
GRANT ALL ON public.eod_reports TO service_role;
ALTER TABLE public.eod_reports ENABLE ROW LEVEL SECURITY;

CREATE INDEX user_roles_user_id_idx ON public.user_roles(user_id);
CREATE INDEX tasks_assignee_created_idx ON public.tasks(assignee_id, created_at DESC);
CREATE INDEX tasks_assigned_by_idx ON public.tasks(assigned_by);
CREATE INDEX eod_reports_report_date_idx ON public.eod_reports(report_date DESC);

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = auth.uid()
      AND role = 'admin'::public.app_role
  );
$$;
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

CREATE POLICY profiles_owner_or_admin_select
ON public.profiles FOR SELECT TO authenticated
USING (id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

CREATE POLICY user_roles_owner_or_admin_select
ON public.user_roles FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

CREATE POLICY tasks_owner_or_admin_select
ON public.tasks FOR SELECT TO authenticated
USING (assignee_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

CREATE POLICY tasks_admin_insert
ON public.tasks FOR INSERT TO authenticated
WITH CHECK ((SELECT public.is_admin()));

CREATE POLICY tasks_owner_or_admin_update
ON public.tasks FOR UPDATE TO authenticated
USING (assignee_id = (SELECT auth.uid()) OR (SELECT public.is_admin()))
WITH CHECK (assignee_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

CREATE POLICY eod_reports_owner_or_admin_select
ON public.eod_reports FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

CREATE POLICY eod_reports_owner_insert
ON public.eod_reports FOR INSERT TO authenticated
WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY eod_reports_owner_update
ON public.eod_reports FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.create_profile_and_role_for_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  selected_role public.app_role;
  profile_name text;
  profile_department text;
BEGIN
  profile_name := COALESCE(
    NULLIF(BTRIM(NEW.raw_user_meta_data ->> 'full_name'), ''),
    NULLIF(SPLIT_PART(COALESCE(NEW.email, ''), '@', 1), ''),
    'Team member'
  );
  profile_department := NULLIF(BTRIM(NEW.raw_user_meta_data ->> 'department'), '');
  IF profile_department NOT IN ('Developer', 'Designer', 'Backend Developer', 'HR') THEN
    profile_department := NULL;
  END IF;

  INSERT INTO public.profiles (id, full_name, department)
  VALUES (NEW.id, profile_name, profile_department)
  ON CONFLICT (id) DO NOTHING;

  PERFORM pg_advisory_xact_lock(hashtext('team_task_first_admin')::bigint);
  IF EXISTS (SELECT 1 FROM public.user_roles WHERE role = 'admin'::public.app_role) THEN
    selected_role := 'member'::public.app_role;
  ELSE
    selected_role := 'admin'::public.app_role;
  END IF;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, selected_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.create_profile_and_role_for_new_user() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER on_auth_user_created_team_workspace
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.create_profile_and_role_for_new_user();

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_set_updated_at
BEFORE UPDATE ON public.tasks
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER eod_reports_set_updated_at
BEFORE UPDATE ON public.eod_reports
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();