# Incident Response Task — Diagnose & Fix a Broken Production Stack

A production-like, intentionally-broken environment used to practice real-world
on-call incident response: diagnosing issues purely from observability data
(logs, metrics, database status), fixing them with minimal blast radius, and
adding monitoring so the same failures page an engineer automatically next time.

**Stack:** Ansible · Docker Swarm · Nginx · Node.js (Express) · Redis · MySQL
(Primary–Replica) · ELK (Elasticsearch, Logstash, Kibana) · Prometheus · Alertmanager

---

## What this is

Unlike a typical "build an app" exercise, this project starts from a **working
stack**, deliberately injects four realistic misconfigurations into it, and
then works through a full incident-response cycle for each one:

1. **Diagnose** the symptom using only observability tools — no guessing.
2. **Fix** it with a rolling, single-replica-at-a-time change (no full outage).
3. **Verify** the fix with before/after evidence, not just "the config looks right."
4. **Prevent recurrence** with a Prometheus alert that would have caught it.

The full narrative — investigation steps, exact commands, log snippets, and
before/after metrics for all four faults — is written up in
[`docs/Incident_RCA_Postmortem.docx`](docs/Incident_RCA_Postmortem.docx).

## Architecture

```
                        ┌─────────────┐
  client ── :8080 ──▶   │    Nginx    │  (reverse proxy, passive health checks)
                        └──────┬──────┘
                     ┌─────────┴─────────┐
                     ▼                   ▼
              ┌─────────────┐     ┌─────────────┐
              │ crud-api-1  │     │ crud-api-2  │   Node.js / Express
              └──────┬──────┘     └──────┬──────┘
                     │                   │
           ┌─────────┴───────┐   ┌───────┴────────┐
           ▼                 ▼   ▼                ▼
     ┌───────────┐    ┌────────────┐       ┌─────────────┐
     │   Redis   │    │mysql-primary├──────▶│mysql-replica│
     │  (cache)  │    └────────────┘        └─────────────┘

  logs from all services ──▶ Logstash ──▶ Elasticsearch ──▶ Kibana

  Prometheus ◀── nginx-exporter / redis-exporter / mysqld-exporter (x2)
       │
       ▼
  Alertmanager
```

All services run as a single Docker Swarm stack on one overlay network.
Nginx (port 8080) is the only externally published application entry point.

## Repository layout

```
.
├── inventory/              # Ansible inventory (single-node Swarm manager)
├── group_vars/
├── roles/
│   ├── nodejs_api/files/   # Express CRUD app + Dockerfile
│   ├── nginx/files/        # nginx.conf
│   ├── redis/files/        # redis.conf
│   ├── mysql/files/        # my-primary.cnf, my-replica.cnf, exporter configs
│   └── elk/files/          # elasticsearch.yml, logstash.conf, logstash.yml, kibana.yml
├── stack/
│   └── docker-stack.yml    # Full Swarm stack definition (app + monitoring)
├── alerting/
│   ├── prometheus/         # prometheus.yml
│   ├── rules/              # nginx/redis/mysql/logstash alert rules
│   ├── alertmanager/       # alertmanager.yml
│   └── scripts/            # logstash_drop_check.sh (ES-based pipeline health check)
├── playbooks/
│   ├── deploy-stack.yml    # Stands up the environment + MySQL replication
│   ├── chaos-inject.yml    # Injects the 4 faults described below
│   └── apply-fixes.yml     # Applies the verified fix for each fault
├── docs/
│   ├── evidence/           # Raw before/after command output captured during triage
│   └── Incident_RCA_Postmortem.docx
└── README.md
```

## The four injected faults

| # | Component | Fault | Symptom |
|---|-----------|-------|---------|
| 1 | Nginx | `max_fails=0` on one upstream disables its passive health check | Intermittent 502/504 errors |
| 2 | Redis | `maxmemory` set below Redis's own baseline memory footprint | Stale reads / OOM write errors |
| 3 | MySQL | `replica_parallel_workers=0` forces single-threaded replication apply | Replica data minutes behind primary |
| 4 | Logstash | Unconditional `drop{}` filter silently discards events missing a field | Logs missing from Kibana, no errors anywhere |

Each fault, its root cause, the exact evidence used to isolate it, the fix, and
the verification are documented in detail in the RCA report.

## Running it

Requires Docker (with Swarm mode) and Ansible with the `community.docker`
collection on a single host.

```bash
# 1. Stand up the environment
ansible-playbook -i inventory/hosts.ini playbooks/deploy-stack.yml

# 2. (Optional) Reproduce the four faults from scratch
ansible-playbook -i inventory/hosts.ini playbooks/chaos-inject.yml

# 3. Apply the verified fixes
ansible-playbook -i inventory/hosts.ini playbooks/apply-fixes.yml

# Check everything is healthy
docker stack services incident
```

The API is reachable at `http://127.0.0.1:8080`, Kibana at `:5601`,
Elasticsearch at `:9200`, Prometheus at `:9090`, and Alertmanager at `:9093`.

> **Note:** Docker configs are immutable by content — re-running a playbook
> after actually editing a config's content requires bumping that config's
> name (see the versioned `configs:` entries in `stack/docker-stack.yml`),
> the same way a real Swarm rolling config update would.

## Monitoring & alerting

Prometheus scrapes Nginx, Redis, and both MySQL nodes via dedicated exporters
and evaluates 12 alert rules across four rule groups (`alerting/rules/`),
one group per fault above. Logstash does not expose Prometheus-format metrics
without an additional plugin not present in the stock image, so its pipeline
health is instead checked by `alerting/scripts/logstash_drop_check.sh`, which
compares expected vs. actually-indexed Elasticsearch document counts on a
schedule — catching the exact silent-drop failure mode described in fault #4.

## Deliverables checklist

- [x] Root Cause Analysis document (symptom → evidence → root cause → fix → verification, all four faults)
- [x] Ansible playbook that stands up the environment
- [x] Ansible playbook that injects the faults (self-designed)
- [x] Ansible playbook / configs containing the verified fixes, version-controlled
- [x] Prometheus alerting rules for each root cause
- [x] Blameless postmortem (timeline, impact, root causes, action items)
