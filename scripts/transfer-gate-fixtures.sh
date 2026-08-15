#!/usr/bin/env bash
#
# Creates the databases and tables that TransferLiveServerGateTests expects.
#
# Idempotent: a table already holding the right number of rows is left alone,
# so re-running only fills in what is missing. Seeding a million rows takes a
# couple of minutes on a cold database.
#
#   MySQL      ss_gate_src / ss_gate_dst on 127.0.0.1:33062 as root
#   PostgreSQL ss_gate_src / ss_gate_dst on 127.0.0.1:5432  as postgres
#
# Override the connection details with the environment variables below.
#
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-33062}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-root}"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD

BENCH_ROWS="${BENCH_ROWS:-1000000}"
SMALL_ROWS="${SMALL_ROWS:-300000}"
CHILD_ROWS="${CHILD_ROWS:-200000}"
SNAPSHOT_ROWS="${SNAPSHOT_ROWS:-200000}"

# The clients are not always installed on the host. When they are missing,
# fall back to running them inside the server's own container.
MYSQL_CONTAINER="${MYSQL_CONTAINER:-tornado.mysql}"
PG_CONTAINER="${PG_CONTAINER:-share.postgres}"

my() {
    if command -v mysql >/dev/null 2>&1; then
        mysql --protocol=TCP -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            --default-character-set=utf8mb4 -N -B "$@" 2>/dev/null
    else
        docker exec -i "$MYSQL_CONTAINER" \
            mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --default-character-set=utf8mb4 -N -B "$@" 2>/dev/null
    fi
}

pg() {
    if command -v psql >/dev/null 2>&1; then
        psql -v ON_ERROR_STOP=1 -q -t -A "$@"
    else
        docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
            psql -U "$PGUSER" -v ON_ERROR_STOP=1 -q -t -A "$@"
    fi
}

my_count() {
    my -e "SELECT COUNT(*) FROM \`$1\`.\`$2\`" 2>/dev/null || echo -1
}

pg_count() {
    pg -d "$1" -c "SELECT COUNT(*) FROM $2" 2>/dev/null || echo -1
}

log() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- MySQL

seed_mysql() {
    echo "MySQL $MYSQL_HOST:$MYSQL_PORT"
    my -e "CREATE DATABASE IF NOT EXISTS ss_gate_src; CREATE DATABASE IF NOT EXISTS ss_gate_dst;"

    mysql_schema ss_gate_src
    mysql_schema ss_gate_dst
    # bench_child only ever exists at the source: it is there so preflight has a
    # foreign key to complain about. At the target its foreign key would make
    # bench undroppable and copy mode could never replace the table.
    my ss_gate_dst -e "DROP TABLE IF EXISTS bench_child;"

    seed_mysql_bench bench "$BENCH_ROWS"
    seed_mysql_bench bench_small "$SMALL_ROWS"

    if [ "$(my_count ss_gate_src bench_child)" -ne "$CHILD_ROWS" ]; then
        log "seeding bench_child ($CHILD_ROWS rows)"
        my ss_gate_src -e "
            SET SESSION cte_max_recursion_depth = $((CHILD_ROWS + 100));
            DELETE FROM bench_child;
            INSERT INTO bench_child (bench_id, label)
            WITH RECURSIVE seq(n) AS (
                SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $CHILD_ROWS
            )
            SELECT n, CONCAT('label-', n) FROM seq;
        "
    fi

    if [ "$(my_count ss_gate_src big_blob)" -ne 1 ]; then
        log "seeding big_blob (one 10MB row)"
        my ss_gate_src -e "DELETE FROM big_blob; INSERT INTO big_blob (body) VALUES (REPEAT('x', 10485760));"
    fi

    if [ "$(my_count ss_gate_src gapped)" -ne 1000 ]; then
        log "seeding gapped (1000 rows, wide gaps)"
        my ss_gate_src -e "
            SET SESSION cte_max_recursion_depth = 2000;
            DELETE FROM gapped;
            INSERT INTO gapped (id, filler)
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
            SELECT n * 100000, CONCAT('filler-', n) FROM seq;
        "
    fi

    for table in snap_a snap_b; do
        if [ "$(my_count ss_gate_src $table)" -ne "$SNAPSHOT_ROWS" ]; then
            log "seeding $table ($SNAPSHOT_ROWS rows)"
            my ss_gate_src -e "
                SET SESSION cte_max_recursion_depth = $((SNAPSHOT_ROWS + 100));
                DELETE FROM $table;
                INSERT INTO $table (tag)
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $SNAPSHOT_ROWS
                )
                SELECT CONCAT('$table-', n) FROM seq;
            "
        fi
    done
}

mysql_schema() {
    my "$1" -e "
        CREATE TABLE IF NOT EXISTS bench (
            id BIGINT NOT NULL AUTO_INCREMENT,
            name VARCHAR(120) NOT NULL,
            amount DECIMAL(12,2) NOT NULL,
            created_at DATETIME NOT NULL,
            payload VARBINARY(256) DEFAULT NULL,
            note TEXT,
            PRIMARY KEY (id),
            KEY by_recent (created_at DESC, name)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS bench_small LIKE bench;

        CREATE TABLE IF NOT EXISTS bench_child (
            id BIGINT NOT NULL AUTO_INCREMENT,
            bench_id BIGINT NOT NULL,
            label VARCHAR(64) NOT NULL,
            PRIMARY KEY (id),
            KEY bench_id (bench_id),
            CONSTRAINT fk_bench_child FOREIGN KEY (bench_id) REFERENCES bench (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS big_blob (
            id INT NOT NULL AUTO_INCREMENT,
            body LONGBLOB NOT NULL,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS gapped (
            id BIGINT NOT NULL,
            filler VARCHAR(80) NOT NULL,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS snap_a (
            id BIGINT NOT NULL AUTO_INCREMENT,
            tag VARCHAR(64) NOT NULL,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS snap_b LIKE snap_a;
    "

}

seed_mysql_bench() {
    local table="$1" rows="$2"
    [ "$(my_count ss_gate_src "$table")" -eq "$rows" ] && return 0
    log "seeding $table ($rows rows)"
    my ss_gate_src -e "
        SET SESSION cte_max_recursion_depth = $((rows + 100));
        DELETE FROM \`$table\`;
        INSERT INTO \`$table\` (name, amount, created_at, payload, note)
        WITH RECURSIVE seq(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $rows
        )
        SELECT
            CONCAT('name-', n),
            ROUND((n % 100000) / 100, 2),
            NOW() - INTERVAL n SECOND,
            RANDOM_BYTES(32),
            CONCAT('note-', n)
        FROM seq;
    "
}

# ----------------------------------------------------------- PostgreSQL

seed_postgres() {
    echo "PostgreSQL $PGHOST:$PGPORT"
    for database in ss_gate_src ss_gate_dst; do
        pg -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$database'" | grep -q 1 \
            || pg -d postgres -c "CREATE DATABASE $database"
    done

    for database in ss_gate_src ss_gate_dst; do
        postgres_schema "$database"
    done

    seed_postgres_bench bench "$BENCH_ROWS"
    seed_postgres_bench bench_small "$SMALL_ROWS"

    if [ "$(pg_count ss_gate_src gapped)" -ne 1000 ]; then
        log "seeding gapped (1000 rows, wide gaps)"
        pg -d ss_gate_src -c "
            TRUNCATE gapped;
            INSERT INTO gapped (id, filler)
            SELECT n * 100000, 'filler-' || n FROM generate_series(1, 1000) AS s(n);
        "
    fi

    for table in snap_a snap_b; do
        if [ "$(pg_count ss_gate_src $table)" -ne "$SNAPSHOT_ROWS" ]; then
            log "seeding $table ($SNAPSHOT_ROWS rows)"
            pg -d ss_gate_src -c "
                TRUNCATE $table RESTART IDENTITY;
                INSERT INTO $table (tag)
                SELECT '$table-' || n FROM generate_series(1, $SNAPSHOT_ROWS) AS s(n);
            "
        fi
    done
}

postgres_schema() {
    pg -d "$1" -c "
        CREATE TABLE IF NOT EXISTS bench (
            id BIGSERIAL PRIMARY KEY,
            name VARCHAR(120) NOT NULL,
            amount NUMERIC(12,2) NOT NULL,
            created_at TIMESTAMP NOT NULL,
            payload BYTEA,
            note TEXT
        );
        CREATE INDEX IF NOT EXISTS by_recent ON bench (created_at DESC, name);

        CREATE TABLE IF NOT EXISTS bench_small (LIKE bench INCLUDING ALL);

        CREATE TABLE IF NOT EXISTS gapped (
            id BIGINT PRIMARY KEY,
            filler VARCHAR(80) NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snap_a (
            id BIGSERIAL PRIMARY KEY,
            tag VARCHAR(64) NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snap_b (
            id BIGSERIAL PRIMARY KEY,
            tag VARCHAR(64) NOT NULL
        );
    "

}

seed_postgres_bench() {
    local table="$1" rows="$2"
    [ "$(pg_count ss_gate_src "$table")" -eq "$rows" ] && return 0
    log "seeding $table ($rows rows)"
    pg -d ss_gate_src -c "
        TRUNCATE $table RESTART IDENTITY;
        INSERT INTO $table (name, amount, created_at, payload, note)
        SELECT
            'name-' || n,
            ROUND(((n % 100000) / 100.0)::numeric, 2),
            NOW() - (n || ' seconds')::interval,
            gen_random_bytes(32),
            'note-' || n
        FROM generate_series(1, $rows) AS s(n);
    "
}

seed_mysql
seed_postgres
echo "Fixtures ready."
