-- SG Technical V5 production migration
-- Run this in Supabase SQL Editor before using the production build.

-- Core fields required by the app
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check CHECK (role IN ('owner','admin','manager','technician','cashier'));
ALTER TABLE public.technicians ADD COLUMN IF NOT EXISTS whatsapp TEXT;
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS other NUMERIC(12,2) DEFAULT 0;
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS subtotal NUMERIC(12,2) DEFAULT 0;
ALTER TABLE public.jobs ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Services used by New Job
CREATE TABLE IF NOT EXISTS public.services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  price NUMERIC(12,2) DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Business settings / staff terms. One row per installation/business.
CREATE TABLE IF NOT EXISTS public.business_settings (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id=1),
  business_name TEXT NOT NULL DEFAULT 'SG Technical',
  logo_data TEXT,
  staff_terms TEXT,
  visit_rate_per_km NUMERIC(12,2) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.business_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Normalize legacy admin role to owner.
UPDATE public.profiles SET role='owner' WHERE role='admin';

-- Recalculate paid/due from the payment ledger.
CREATE OR REPLACE FUNCTION public.recalculate_job(p_job_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_total NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
  SELECT COALESCE(total,0) INTO v_total FROM public.jobs WHERE id=p_job_id;
  SELECT COALESCE(SUM(amount),0) INTO v_paid FROM public.payments WHERE job_id=p_job_id;
  UPDATE public.jobs
  SET paid=v_paid, due=GREATEST(v_total-v_paid,0), updated_at=NOW()
  WHERE id=p_job_id;
  UPDATE public.invoices
  SET paid_amount=v_paid,
      due_amount=GREATEST(v_total-v_paid,0),
      status=CASE WHEN GREATEST(v_total-v_paid,0)<=0 THEN 'Paid'
                  WHEN v_paid>0 THEN 'Partially Paid' ELSE 'Unpaid' END
  WHERE job_id=p_job_id;
END; $$;

CREATE OR REPLACE FUNCTION public.sg_payment_recalc_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  PERFORM public.recalculate_job(COALESCE(NEW.job_id,OLD.job_id));
  RETURN COALESCE(NEW,OLD);
END; $$;
DROP TRIGGER IF EXISTS trg_sg_payment_recalc ON public.payments;
CREATE TRIGGER trg_sg_payment_recalc
AFTER INSERT OR UPDATE OR DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.sg_payment_recalc_trigger();

-- Helper for RLS. SECURITY DEFINER avoids profiles-policy recursion.
CREATE OR REPLACE FUNCTION public.sg_role()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE((SELECT role FROM public.profiles WHERE id=auth.uid()),'')::TEXT;
$$;

-- Remove the demo-public policies from the production tables.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','customers','technicians','jobs','payments','invoices','stock_items','stock_transactions','expenses','services','business_settings'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS sg_demo_public_all ON public.%I',t);
  END LOOP;
END $$;

-- Profiles: users can see their own profile; owner can manage roles.
DROP POLICY IF EXISTS sg_profiles_self_select ON public.profiles;
CREATE POLICY sg_profiles_self_select ON public.profiles FOR SELECT TO authenticated USING (id=auth.uid() OR sg_role()='owner');
DROP POLICY IF EXISTS sg_profiles_owner_update ON public.profiles;
CREATE POLICY sg_profiles_owner_update ON public.profiles FOR UPDATE TO authenticated USING (sg_role()='owner') WITH CHECK (sg_role()='owner');

-- Customers
DROP POLICY IF EXISTS sg_customers_select ON public.customers;
CREATE POLICY sg_customers_select ON public.customers FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_customers_write ON public.customers;
CREATE POLICY sg_customers_write ON public.customers FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));

-- Technicians
DROP POLICY IF EXISTS sg_technicians_select ON public.technicians;
CREATE POLICY sg_technicians_select ON public.technicians FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_technicians_write ON public.technicians;
CREATE POLICY sg_technicians_write ON public.technicians FOR ALL TO authenticated USING (sg_role()='owner') WITH CHECK (sg_role()='owner');

-- Jobs: technician can only see/update assigned jobs; owner/manager full access; cashier read-only.
DROP POLICY IF EXISTS sg_jobs_select ON public.jobs;
CREATE POLICY sg_jobs_select ON public.jobs FOR SELECT TO authenticated USING (
  sg_role() IN ('owner','manager','cashier') OR (sg_role()='technician' AND lower(COALESCE(technician_name,''))=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),'')))
);
DROP POLICY IF EXISTS sg_jobs_insert ON public.jobs;
CREATE POLICY sg_jobs_insert ON public.jobs FOR INSERT TO authenticated WITH CHECK (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_jobs_update ON public.jobs;
CREATE POLICY sg_jobs_update ON public.jobs FOR UPDATE TO authenticated USING (
  sg_role() IN ('owner','manager') OR (sg_role()='technician' AND lower(COALESCE(technician_name,''))=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),'')))
) WITH CHECK (
  sg_role() IN ('owner','manager') OR (sg_role()='technician' AND lower(COALESCE(technician_name,''))=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),'')))
);
DROP POLICY IF EXISTS sg_jobs_delete ON public.jobs;
CREATE POLICY sg_jobs_delete ON public.jobs FOR DELETE TO authenticated USING (sg_role()='owner');

-- Payments: owner/manager/cashier can read; cashier can add; owner/manager can edit/delete.
DROP POLICY IF EXISTS sg_payments_select ON public.payments;
CREATE POLICY sg_payments_select ON public.payments FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_payments_insert ON public.payments;
CREATE POLICY sg_payments_insert ON public.payments FOR INSERT TO authenticated WITH CHECK (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_payments_update ON public.payments;
CREATE POLICY sg_payments_update ON public.payments FOR UPDATE TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_payments_delete ON public.payments;
CREATE POLICY sg_payments_delete ON public.payments FOR DELETE TO authenticated USING (sg_role()='owner');

-- Invoices
DROP POLICY IF EXISTS sg_invoices_select ON public.invoices;
CREATE POLICY sg_invoices_select ON public.invoices FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_invoices_insert ON public.invoices;
CREATE POLICY sg_invoices_insert ON public.invoices FOR INSERT TO authenticated WITH CHECK (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_invoices_update ON public.invoices;
CREATE POLICY sg_invoices_update ON public.invoices FOR UPDATE TO authenticated USING (sg_role()='owner') WITH CHECK (sg_role()='owner');
DROP POLICY IF EXISTS sg_invoices_delete ON public.invoices;
CREATE POLICY sg_invoices_delete ON public.invoices FOR DELETE TO authenticated USING (sg_role()='owner');

-- Stock
DROP POLICY IF EXISTS sg_stock_select ON public.stock_items;
CREATE POLICY sg_stock_select ON public.stock_items FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_stock_write ON public.stock_items;
CREATE POLICY sg_stock_write ON public.stock_items FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));

DROP POLICY IF EXISTS sg_stocktx_select ON public.stock_transactions;
CREATE POLICY sg_stocktx_select ON public.stock_transactions FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_stocktx_write ON public.stock_transactions;
CREATE POLICY sg_stocktx_write ON public.stock_transactions FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));

-- Expenses
DROP POLICY IF EXISTS sg_expenses_select ON public.expenses;
CREATE POLICY sg_expenses_select ON public.expenses FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_expenses_write ON public.expenses;
CREATE POLICY sg_expenses_write ON public.expenses FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));

-- Services
DROP POLICY IF EXISTS sg_services_select ON public.services;
CREATE POLICY sg_services_select ON public.services FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier'));
DROP POLICY IF EXISTS sg_services_write ON public.services;
CREATE POLICY sg_services_write ON public.services FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));

-- Business settings / staff terms
DROP POLICY IF EXISTS sg_business_settings_select ON public.business_settings;
CREATE POLICY sg_business_settings_select ON public.business_settings FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS sg_business_settings_update ON public.business_settings;
CREATE POLICY sg_business_settings_update ON public.business_settings FOR UPDATE TO authenticated USING (sg_role()='owner') WITH CHECK (sg_role()='owner');

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.services, public.business_settings TO authenticated;
GRANT EXECUTE ON FUNCTION public.sg_role(), public.recalculate_job(UUID) TO authenticated;


-- ================================================================
-- V5.1: Staff, permissions, customer portal, photos, feedback
-- ================================================================
CREATE TABLE IF NOT EXISTS public.role_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role TEXT NOT NULL CHECK (role IN ('owner','manager','cashier','technician')),
  module TEXT NOT NULL,
  can_view BOOLEAN NOT NULL DEFAULT FALSE,
  can_add BOOLEAN NOT NULL DEFAULT FALSE,
  can_edit BOOLEAN NOT NULL DEFAULT FALSE,
  can_delete BOOLEAN NOT NULL DEFAULT FALSE,
  can_assign BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(role,module)
);

CREATE TABLE IF NOT EXISTS public.staff_salary_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  technician_id UUID REFERENCES public.technicians(id) ON DELETE SET NULL,
  salary_month DATE NOT NULL,
  monthly_salary NUMERIC(12,2) NOT NULL DEFAULT 0,
  advance NUMERIC(12,2) NOT NULL DEFAULT 0,
  bonus NUMERIC(12,2) NOT NULL DEFAULT 0,
  overtime NUMERIC(12,2) NOT NULL DEFAULT 0,
  deduction NUMERIC(12,2) NOT NULL DEFAULT 0,
  salary_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  remaining_salary NUMERIC(12,2) GENERATED ALWAYS AS (GREATEST(monthly_salary+bonus+overtime-advance-deduction-salary_paid,0)) STORED,
  payment_date DATE,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.customer_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  address TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  service_id UUID REFERENCES public.services(id) ON DELETE SET NULL,
  service_name TEXT,
  preferred_date DATE,
  preferred_time TEXT,
  problem_description TEXT,
  distance_km NUMERIC(10,2) DEFAULT 0,
  visit_rate_per_km NUMERIC(12,2) DEFAULT 0,
  visit_charges NUMERIC(12,2) DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'Pending' CHECK(status IN ('Pending','Confirmed','Technician Assigned','Work in Process','Completed','Cancelled')),
  job_id UUID REFERENCES public.jobs(id) ON DELETE SET NULL,
  terms_agreed BOOLEAN NOT NULL DEFAULT FALSE,
  terms_agreed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.customer_booking_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES public.customer_bookings(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.job_work_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  technician_id UUID REFERENCES public.technicians(id) ON DELETE SET NULL,
  storage_path TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_job_work_photos_job ON public.job_work_photos(job_id);

CREATE TABLE IF NOT EXISTS public.customer_feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES public.customer_bookings(id) ON DELETE SET NULL,
  job_id UUID REFERENCES public.jobs(id) ON DELETE SET NULL,
  customer_id UUID REFERENCES public.customers(id) ON DELETE SET NULL,
  rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),
  review TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Default permission matrix. Owner is always full control; the UI can later override individual cells.
INSERT INTO public.role_permissions(role,module,can_view,can_add,can_edit,can_delete,can_assign)
VALUES
('owner','dashboard',TRUE,TRUE,TRUE,TRUE,TRUE),('owner','customers',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','technicians',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','jobs',TRUE,TRUE,TRUE,TRUE,TRUE),('owner','services',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','stock',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','invoices',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','payments',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','expenses',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','salary',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','bookings',TRUE,TRUE,TRUE,TRUE,TRUE),('owner','feedback',TRUE,TRUE,TRUE,TRUE,FALSE),('owner','settings',TRUE,TRUE,TRUE,TRUE,FALSE),
('manager','dashboard',TRUE,FALSE,FALSE,FALSE,FALSE),('manager','customers',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','technicians',TRUE,FALSE,FALSE,FALSE,FALSE),('manager','jobs',TRUE,TRUE,TRUE,FALSE,TRUE),('manager','services',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','stock',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','invoices',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','payments',TRUE,TRUE,FALSE,FALSE,FALSE),('manager','expenses',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','salary',TRUE,TRUE,TRUE,FALSE,FALSE),('manager','bookings',TRUE,TRUE,TRUE,FALSE,TRUE),('manager','feedback',TRUE,FALSE,FALSE,FALSE,FALSE),
('cashier','dashboard',TRUE,FALSE,FALSE,FALSE,FALSE),('cashier','customers',TRUE,FALSE,FALSE,FALSE,FALSE),('cashier','jobs',TRUE,FALSE,FALSE,FALSE,FALSE),('cashier','invoices',TRUE,TRUE,FALSE,FALSE,FALSE),('cashier','payments',TRUE,TRUE,FALSE,FALSE,FALSE),('cashier','expenses',TRUE,TRUE,FALSE,FALSE,FALSE),('cashier','feedback',TRUE,FALSE,FALSE,FALSE,FALSE),
('technician','dashboard',TRUE,FALSE,FALSE,FALSE,FALSE),('technician','jobs',TRUE,FALSE,TRUE,FALSE,FALSE),('technician','feedback',TRUE,FALSE,FALSE,FALSE,FALSE)
ON CONFLICT(role,module) DO NOTHING;

-- Secure RLS for new tables.
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_salary_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_booking_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_work_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sg_role_permissions_owner ON public.role_permissions;
DROP POLICY IF EXISTS sg_role_permissions_read ON public.role_permissions;
DROP POLICY IF EXISTS sg_role_permissions_update ON public.role_permissions;
DROP POLICY IF EXISTS sg_role_permissions_insert ON public.role_permissions;
DROP POLICY IF EXISTS sg_role_permissions_delete ON public.role_permissions;
CREATE POLICY sg_role_permissions_read ON public.role_permissions FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier','technician'));
-- Owner permissions are immutable: the Owner may manage every other role, but cannot remove Owner's own full-control row.
CREATE POLICY sg_role_permissions_update ON public.role_permissions FOR UPDATE TO authenticated USING (sg_role()='owner' AND role<>'owner') WITH CHECK (sg_role()='owner' AND role<>'owner');
CREATE POLICY sg_role_permissions_insert ON public.role_permissions FOR INSERT TO authenticated WITH CHECK (sg_role()='owner' AND role<>'owner');
CREATE POLICY sg_role_permissions_delete ON public.role_permissions FOR DELETE TO authenticated USING (sg_role()='owner' AND role<>'owner');

DROP POLICY IF EXISTS sg_salary_manage ON public.staff_salary_records;
CREATE POLICY sg_salary_manage ON public.staff_salary_records FOR ALL TO authenticated USING (sg_role() IN ('owner','manager')) WITH CHECK (sg_role() IN ('owner','manager'));
DROP POLICY IF EXISTS sg_salary_self ON public.staff_salary_records;
CREATE POLICY sg_salary_self ON public.staff_salary_records FOR SELECT TO authenticated USING (staff_profile_id=auth.uid());

DROP POLICY IF EXISTS sg_bookings_staff ON public.customer_bookings;
CREATE POLICY sg_bookings_staff ON public.customer_bookings FOR ALL TO authenticated USING (sg_role() IN ('owner','manager','cashier')) WITH CHECK (sg_role() IN ('owner','manager','cashier'));

DROP POLICY IF EXISTS sg_booking_photos_staff ON public.customer_booking_photos;
CREATE POLICY sg_booking_photos_staff ON public.customer_booking_photos FOR ALL TO authenticated USING (sg_role() IN ('owner','manager','cashier')) WITH CHECK (sg_role() IN ('owner','manager','cashier'));

DROP POLICY IF EXISTS sg_work_photos_staff ON public.job_work_photos;
CREATE POLICY sg_work_photos_staff ON public.job_work_photos FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager') OR technician_id IN (SELECT id FROM public.technicians WHERE lower(name)=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),''))));
DROP POLICY IF EXISTS sg_work_photos_tech_insert ON public.job_work_photos;
CREATE POLICY sg_work_photos_tech_insert ON public.job_work_photos FOR INSERT TO authenticated WITH CHECK (sg_role() IN ('owner','manager') OR technician_id IN (SELECT id FROM public.technicians WHERE lower(name)=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),''))));

DROP POLICY IF EXISTS sg_feedback_staff ON public.customer_feedback;
CREATE POLICY sg_feedback_staff ON public.customer_feedback FOR SELECT TO authenticated USING (sg_role() IN ('owner','manager','cashier','technician'));
DROP POLICY IF EXISTS sg_feedback_insert ON public.customer_feedback;
CREATE POLICY sg_feedback_insert ON public.customer_feedback FOR INSERT TO authenticated WITH CHECK (sg_role() IN ('owner','manager','cashier'));

GRANT SELECT,INSERT,UPDATE,DELETE ON public.role_permissions, public.staff_salary_records, public.customer_bookings, public.customer_booking_photos, public.job_work_photos, public.customer_feedback TO authenticated;

-- ================================================================
-- V5.3: Technician completion workflow + secure job updates
-- ================================================================
ALTER TABLE public.jobs DROP CONSTRAINT IF EXISTS jobs_status_check;
ALTER TABLE public.jobs ADD CONSTRAINT jobs_status_check CHECK (status IN ('Pending','Assigned','In Progress','Work in Process','Completed','Cancelled'));

-- Private bucket for technician completion photos. Use signed URLs from the app.
INSERT INTO storage.buckets (id, name, public)
VALUES ('sg-job-work-photos', 'sg-job-work-photos', FALSE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS sg_job_photo_upload ON storage.objects;
CREATE POLICY sg_job_photo_upload ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id='sg-job-work-photos' AND
  (sg_role() IN ('owner','manager') OR EXISTS (
    SELECT 1 FROM public.jobs j JOIN public.technicians t ON t.id=j.technician_id
    WHERE j.id::text=split_part(name,'/',1)
      AND lower(t.name)=lower(COALESCE((SELECT full_name FROM public.profiles WHERE id=auth.uid()),''))
  ))
);
DROP POLICY IF EXISTS sg_job_photo_read ON storage.objects;
CREATE POLICY sg_job_photo_read ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='sg-job-work-photos' AND sg_role() IN ('owner','manager','technician'));

CREATE OR REPLACE FUNCTION public.sg_guard_technician_job_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF sg_role()='technician' THEN
    IF lower(COALESCE(OLD.technician_name,'')) <> lower(COALESCE((SELECT full_name FROM profiles WHERE id=auth.uid()),'')) THEN
      RAISE EXCEPTION 'You can only update your assigned jobs';
    END IF;
    IF NEW.customer_id IS DISTINCT FROM OLD.customer_id OR NEW.customer_name IS DISTINCT FROM OLD.customer_name
       OR NEW.customer_phone IS DISTINCT FROM OLD.customer_phone OR NEW.technician_id IS DISTINCT FROM OLD.technician_id
       OR NEW.technician_name IS DISTINCT FROM OLD.technician_name OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.paid IS DISTINCT FROM OLD.paid OR NEW.due IS DISTINCT FROM OLD.due OR NEW.labour IS DISTINCT FROM OLD.labour
       OR NEW.parts IS DISTINCT FROM OLD.parts OR NEW.other IS DISTINCT FROM OLD.other OR NEW.discount IS DISTINCT FROM OLD.discount THEN
      RAISE EXCEPTION 'Technician cannot edit customer, assignment or billing fields';
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_guard_technician_job_update ON public.jobs;
CREATE TRIGGER trg_guard_technician_job_update BEFORE UPDATE ON public.jobs
FOR EACH ROW EXECUTE FUNCTION public.sg_guard_technician_job_update();

-- ================================================================
-- V5.4: Parts catalog + technician used-parts billing
-- ================================================================

CREATE TABLE IF NOT EXISTS public.job_parts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  stock_item_id UUID NOT NULL REFERENCES public.stock_items(id),
  technician_id UUID REFERENCES public.technicians(id),
  item_name TEXT NOT NULL,
  quantity NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
  sale_rate NUMERIC(12,2) NOT NULL CHECK (sale_rate >= 0),
  amount NUMERIC(12,2) GENERATED ALWAYS AS (quantity * sale_rate) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_job_parts_job ON public.job_parts(job_id);
CREATE INDEX IF NOT EXISTS idx_job_parts_item ON public.job_parts(stock_item_id);

ALTER TABLE public.job_parts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sg_job_parts_staff_select ON public.job_parts;
CREATE POLICY sg_job_parts_staff_select ON public.job_parts
FOR SELECT TO authenticated
USING (
  public.sg_current_role() IN ('owner','manager','cashier')
  OR (
    public.sg_current_role() = 'technician'
    AND technician_id = public.sg_current_technician_id()
  )
);

-- Inserts/stock deduction happen through the SECURITY DEFINER RPC below,
-- so technicians do not receive direct stock write access.
DROP POLICY IF EXISTS sg_job_parts_staff_insert ON public.job_parts;
CREATE POLICY sg_job_parts_staff_insert ON public.job_parts
FOR INSERT TO authenticated
WITH CHECK (public.sg_current_role() IN ('owner','manager'));

DROP POLICY IF EXISTS sg_job_parts_owner_delete ON public.job_parts;
CREATE POLICY sg_job_parts_owner_delete ON public.job_parts
FOR DELETE TO authenticated
USING (public.sg_current_role() = 'owner');

GRANT SELECT, INSERT, DELETE ON public.job_parts TO authenticated;

-- Limited catalog: only customer-safe fields are exposed.
-- Purchase price, supplier and internal stock fields are intentionally hidden.
CREATE OR REPLACE VIEW public.customer_parts_catalog AS
SELECT
  id,
  item_code,
  name,
  category,
  unit,
  sale_price,
  quantity AS available_qty,
  CASE WHEN quantity > 0 THEN TRUE ELSE FALSE END AS available
FROM public.stock_items
WHERE quantity >= 0;

CREATE OR REPLACE VIEW public.technician_parts_catalog AS
SELECT
  id,
  item_code,
  name,
  category,
  unit,
  sale_price,
  quantity AS available_qty,
  CASE WHEN quantity > 0 THEN TRUE ELSE FALSE END AS available
FROM public.stock_items
WHERE quantity > 0;

GRANT SELECT ON public.customer_parts_catalog TO anon, authenticated;
GRANT SELECT ON public.technician_parts_catalog TO authenticated;

-- Atomic operation: technician selects a part and quantity; this RPC locks
-- the stock row, checks availability, records the part, deducts stock,
-- records an OUT transaction, and recalculates the job billing.
CREATE OR REPLACE FUNCTION public.sg_add_job_part(
  p_job_id UUID,
  p_stock_item_id UUID,
  p_quantity NUMERIC
)
RETURNS public.job_parts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_job public.jobs%ROWTYPE;
  v_item public.stock_items%ROWTYPE;
  v_part public.job_parts%ROWTYPE;
  v_tech_id UUID;
  v_parts NUMERIC;
  v_subtotal NUMERIC;
  v_total NUMERIC;
  v_due NUMERIC;
BEGIN
  v_role := public.sg_current_role();

  IF v_role NOT IN ('owner','manager','technician') THEN
    RAISE EXCEPTION 'You do not have permission to add job parts';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero';
  END IF;

  SELECT * INTO v_job
  FROM public.jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Job not found';
  END IF;

  IF v_role = 'technician' THEN
    v_tech_id := public.sg_current_technician_id();
    IF v_tech_id IS NULL OR v_job.technician_id IS DISTINCT FROM v_tech_id THEN
      RAISE EXCEPTION 'You can only add parts to your assigned jobs';
    END IF;
  ELSE
    v_tech_id := v_job.technician_id;
  END IF;

  IF v_job.status = 'Cancelled' THEN
    RAISE EXCEPTION 'Parts cannot be added to a cancelled job';
  END IF;

  SELECT * INTO v_item
  FROM public.stock_items
  WHERE id = p_stock_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stock item not found';
  END IF;

  IF COALESCE(v_item.quantity,0) < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock. Available: %', COALESCE(v_item.quantity,0);
  END IF;

  INSERT INTO public.job_parts(
    job_id, stock_item_id, technician_id, item_name, quantity, sale_rate
  )
  VALUES(
    p_job_id, p_stock_item_id, v_tech_id, v_item.name, p_quantity, COALESCE(v_item.sale_price,0)
  )
  RETURNING * INTO v_part;

  UPDATE public.stock_items
  SET quantity = quantity - p_quantity,
      updated_at = NOW()
  WHERE id = p_stock_item_id;

  INSERT INTO public.stock_transactions(
    item_id, job_id, transaction_type, quantity, unit_price, reference_no, notes
  )
  VALUES(
    p_stock_item_id,
    p_job_id,
    'OUT',
    p_quantity,
    COALESCE(v_item.sale_price,0),
    v_job.job_no,
    'Used on job by technician/staff'
  );

  v_parts := COALESCE(v_job.parts,0) + v_part.amount;
  v_subtotal := COALESCE(v_job.labour,0) + v_parts + COALESCE(v_job.other,0);
  v_total := GREATEST(0, v_subtotal - COALESCE(v_job.discount,0));
  v_due := GREATEST(0, v_total - COALESCE(v_job.paid,0));

  UPDATE public.jobs
  SET parts = v_parts,
      subtotal = v_subtotal,
      total = v_total,
      due = v_due,
      updated_at = NOW()
  WHERE id = p_job_id;

  -- Keep any existing invoice synchronized when the billing changes.
  BEGIN
    PERFORM public.recalculate_job(p_job_id);
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN v_part;
END;
$$;

REVOKE ALL ON FUNCTION public.sg_add_job_part(UUID,UUID,NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_add_job_part(UUID,UUID,NUMERIC) TO authenticated;

-- Customer-safe catalog can be read without exposing purchase price.
GRANT USAGE ON SCHEMA public TO anon, authenticated;

