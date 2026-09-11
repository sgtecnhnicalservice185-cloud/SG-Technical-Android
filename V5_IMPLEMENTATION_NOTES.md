# SG Technical V5 implementation notes

This build starts the requested production pass on the V4 source project.

Implemented in the app:
- New Job live Subtotal / Total / Paid / Due calculation.
- Existing-customer selection plus New Customer name/phone creation from New Job.
- Service selector with Add New Service.
- Staff Terms & Conditions screen and editor for Owner/Manager.
- Business name and logo controls persisted on the device.
- Legacy `admin` role is displayed/treated as `owner` in the app.
- Technician job list is filtered to the logged-in technician name.
- Dashboard Outstanding uses job balances instead of only payment totals.
- Android WebView file chooser support for logo/image selection.
- Android versionCode/versionName advanced for the next build.

Backend:
- Run `supabase_production_migration.sql` in Supabase SQL Editor before production use. It adds Services/Business Settings, normalizes the legacy admin role, adds the required fields, recalculates job balances from the payment ledger, and replaces demo-public RLS policies with role-based policies.

Important remaining production work:
- Full Access Management matrix (per-module View/Add/Edit/Delete) needs persistent role-permission storage/UI.
- Staff salary/bonus ledger and customer online booking/portal still need their dedicated database tables/screens.
- Technician completion photo storage (max 5), live location/maps, notifications, ratings/feedback, and per-km visit charge need their storage/functions/UI.
- Owner-managed other-user login IDs/passwords require a secure Supabase Edge Function; never put the service-role key in the Android app.
- Logo is currently device-persisted in this pass; production shared logo should move to Supabase Storage/business_settings.
