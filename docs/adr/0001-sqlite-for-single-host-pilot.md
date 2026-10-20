# Use SQLite for the single-host pipeline pilot

For the first pipeline delivery, Symphony will persist task, run, phase, checkpoint, evidence, and external-operation state in SQLite on one host, with the database and required artifacts on persistent storage. This keeps transactional recovery and idempotent GitHub operations simple for the pilot; multi-host coordination and distributed queues remain out of scope and require revisiting this decision.
