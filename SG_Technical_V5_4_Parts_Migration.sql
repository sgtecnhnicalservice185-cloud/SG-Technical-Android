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
