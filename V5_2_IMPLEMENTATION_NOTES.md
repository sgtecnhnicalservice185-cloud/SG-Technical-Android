# SG Technical V5.2 Implementation Pass

This build continues from V5.1.

## Added in V5.2
- Staff Salary module: monthly salary, advance, bonus, overtime, deduction, paid and remaining salary.
- Salary history backed by `public.staff_salary_records`.
- Customer Bookings management view backed by `public.customer_bookings`.
- Customer Feedback/Ratings view with average rating and review list.
- Owner Access Management UI for View/Add/Edit/Delete/Assign permission cells.
- Owner role permission rows are protected in the production migration so Owner access cannot be removed.
- Business name/logo settings now write to `public.business_settings` when the migration is installed.
- Added Supabase loading for salary, booking and feedback records.

## Still required before Play Store production
- Customer-facing portal registration/login and booking submission UI.
- Secure storage uploads for customer problem photos and technician completion photos (max 5).
- Server-side technician-to-assigned-job identity mapping rather than name-only fallback.
- Complete per-user login ID/password administration via Supabase Auth/Admin workflow.
- Final production RLS audit on every existing table and removal of any demo-public policies.
- Release signing/AAB, privacy policy, Play Console configuration and full device testing.

## Supabase
Run `supabase_production_migration.sql` in the target Supabase project's SQL editor before using the new modules.
