# Speak the Supabase API directly, with no backend abstraction

We want the option to move off Supabase Cloud onto a self-hosted instance without
rewriting the app. Self-hosted Supabase exposes an identical API, so the cheapest
way to get that is to depend on `supabase_flutter` directly and make the base URL
and anon key user-editable settings — changing backend is a config change, not a
code change.

## Considered options

A thin sync interface with pluggable adapters, so the self-hosted side could be
a service of any shape. Rejected: it costs a protocol spec to maintain and an
abstraction layer to keep honest, in exchange for a flexibility we cannot
currently name a use for.

## Consequences

There is deliberately no repository or gateway layer wrapping Supabase calls.
Do not add one "for flexibility" — the flexibility lives in the URL field.
