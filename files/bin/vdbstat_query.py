#!/usr/bin/env python3

import csv
import re
import sys
from pathlib import Path

try:
    import psycopg2
except ImportError:
    print(
        "vdbstat: missing psycopg2. Re-run bootstrap with --visidata.",
        file=sys.stderr,
    )
    sys.exit(1)


QUERIES = {
    "activity": """
        SELECT
          pid,
          usename,
          application_name,
          client_addr,
          state,
          wait_event_type,
          wait_event,
          now() - query_start AS query_age,
          now() - xact_start AS transaction_age,
          left(query, 300) AS query
        FROM pg_stat_activity
        WHERE datname = current_database()
        ORDER BY
          CASE WHEN state = 'active' THEN 0 ELSE 1 END,
          query_start NULLS LAST;
    """,
    "long": """
        SELECT
          pid,
          usename,
          application_name,
          client_addr,
          state,
          wait_event_type,
          wait_event,
          now() - query_start AS query_age,
          now() - xact_start AS transaction_age,
          left(query, 500) AS query
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND state = 'active'
          AND query_start IS NOT NULL
        ORDER BY query_start;
    """,
    "idle": """
        SELECT
          pid,
          usename,
          application_name,
          client_addr,
          state,
          wait_event_type,
          wait_event,
          now() - state_change AS idle_for,
          left(query, 300) AS last_query
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND state = 'idle'
        ORDER BY state_change NULLS LAST;
    """,
    "idle-xact": """
        SELECT
          pid,
          usename,
          application_name,
          client_addr,
          state,
          wait_event_type,
          wait_event,
          now() - xact_start AS transaction_age,
          now() - state_change AS idle_for,
          left(query, 500) AS query
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND state = 'idle in transaction'
        ORDER BY xact_start NULLS LAST;
    """,
    "locks": """
        SELECT
          a.pid,
          a.usename,
          a.state,
          l.locktype,
          l.mode,
          l.granted,
          l.relation::regclass AS relation,
          now() - a.query_start AS query_age,
          left(a.query, 300) AS query
        FROM pg_locks l
        LEFT JOIN pg_stat_activity a
          ON a.pid = l.pid
        WHERE a.datname = current_database()
        ORDER BY
          l.granted,
          a.query_start NULLS LAST;
    """,
    "blocking": """
        SELECT
          blocked.pid AS blocked_pid,
          blocked.usename AS blocked_user,
          now() - blocked.query_start AS blocked_for,
          left(blocked.query, 300) AS blocked_query,
          blocking.pid AS blocking_pid,
          blocking.usename AS blocking_user,
          now() - blocking.query_start AS blocking_for,
          left(blocking.query, 300) AS blocking_query
        FROM pg_stat_activity blocked
        JOIN pg_locks blocked_locks
          ON blocked_locks.pid = blocked.pid
        JOIN pg_locks blocking_locks
          ON blocking_locks.locktype = blocked_locks.locktype
         AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
         AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
         AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
         AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
         AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
         AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
         AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
         AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
         AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
         AND blocking_locks.pid <> blocked_locks.pid
        JOIN pg_stat_activity blocking
          ON blocking.pid = blocking_locks.pid
        WHERE NOT blocked_locks.granted
          AND blocking_locks.granted
          AND blocked.datname = current_database();
    """,
    "tables": """
        SELECT
          schemaname,
          relname,
          n_live_tup,
          n_dead_tup,
          seq_scan,
          idx_scan,
          n_tup_ins,
          n_tup_upd,
          n_tup_del,
          last_vacuum,
          last_autovacuum,
          last_analyze,
          last_autoanalyze
        FROM pg_stat_user_tables
        ORDER BY n_dead_tup DESC;
    """,
    "db": """
        SELECT
          datname,
          numbackends,
          xact_commit,
          xact_rollback,
          blks_read,
          blks_hit,
          round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
          tup_returned,
          tup_fetched,
          tup_inserted,
          tup_updated,
          tup_deleted,
          deadlocks,
          temp_files,
          pg_size_pretty(temp_bytes) AS temp_bytes,
          stats_reset
        FROM pg_stat_database
        WHERE datname = current_database();
    """,
}


def read_connection_aliases(path: Path) -> dict[str, str]:
    if not path.exists():
        raise FileNotFoundError(f"connection file not found: {path}")

    aliases: dict[str, str] = {}
    pattern = re.compile(r"""^([A-Za-z_][A-Za-z0-9_]*)=(['"])(.*)\2\s*$""")

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        match = pattern.match(line)
        if match:
            aliases[match.group(1)] = match.group(3)

    return aliases


def write_csv(rows, headers) -> None:
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(headers)

    for row in rows:
        writer.writerow(row)


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: vdbstat_query.py DATABASE_ALIAS VIEW", file=sys.stderr)
        print("Views: " + ", ".join(sorted(QUERIES)), file=sys.stderr)
        return 1

    db_alias = sys.argv[1]
    view = sys.argv[2]

    if view not in QUERIES:
        print(f"vdbstat: unknown view: {view}", file=sys.stderr)
        print("Views: " + ", ".join(sorted(QUERIES)), file=sys.stderr)
        return 1

    conn_file = Path.home() / ".bashrc.d" / "vdb_connections"
    aliases = read_connection_aliases(conn_file)

    conn_string = aliases.get(db_alias)

    if not conn_string:
        print(
            f"vdbstat: no connection string found for alias: {db_alias}",
            file=sys.stderr,
        )
        print(f"Edit: {conn_file}", file=sys.stderr)
        return 1

    with psycopg2.connect(conn_string) as conn:
        with conn.cursor() as cur:
            cur.execute(QUERIES[view])
            headers = [desc[0] for desc in cur.description]
            rows = cur.fetchall()

    write_csv(rows, headers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
