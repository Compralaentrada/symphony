# Use SQLite as the execution journal for the single-host pipeline pilot

For the first pipeline delivery using Projects v2, GitHub Projects is authoritative for visible task state and human intent. SQLite stores the internal execution journal: task identity, runs, phases, checkpoints, evidence, ownership, and external-operation intents. On restart, Symphony reconciles the current Project and GitHub state before resuming; SQLite must never restore an obsolete visible state or override a newer human decision.

The database and required artifacts live on persistent storage. Transactions and uniqueness constraints support recovery and idempotent GitHub operations on one host. If external state and a checkpoint cannot be reconciled safely, Symphony stops for intervention rather than guessing. Multi-host coordination and distributed queues remain out of scope and require revisiting this decision.
