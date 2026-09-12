# One user, no account model

nem is a personal tool for one person using two devices. No table carries a
`user_id`, there is no assignment, no "completed by", and no permission model;
the single Supabase account exists only to scope the data and let a second device
sign in.

## Consequences

Adding household sharing later is not an incremental change — it touches every
table, every RLS policy, and the completion UI. That cost is accepted in exchange
for a much smaller schema now.
