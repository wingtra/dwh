"""Filter a plain-SQL pg_dump on the fly, skipping COPY blocks for excluded tables.

Reads from stdin, writes to stdout. Schema statements (CREATE TABLE, indexes,
etc.) always pass through -- empty tables for excluded models are fine and keep
the schema consistent.
"""
import re
import sys

COPY_START = re.compile(r'^COPY\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\(')


def filter_stream(stdin, stdout, exclude: set[str]) -> dict[str, int]:
    """Returns counts: rows skipped per table."""
    skipping_table = None
    buffered_statement: list[str] = []
    skipped_counts: dict[str, int] = {}

    for line in stdin:
        if buffered_statement:
            buffered_statement.append(line)
            if line.rstrip().endswith(";"):
                statement = "".join(buffered_statement)
                if "FOREIGN KEY" in statement:
                    skipped_counts["_foreign_key_constraints"] = (
                        skipped_counts.get("_foreign_key_constraints", 0) + 1
                    )
                else:
                    stdout.write(statement)
                buffered_statement = []
            continue

        if skipping_table is not None:
            if line.rstrip() == r"\.":
                skipping_table = None
            else:
                skipped_counts[skipping_table] = skipped_counts.get(skipping_table, 0) + 1
            continue

        m = COPY_START.match(line)
        if m and m.group(1) in exclude:
            skipping_table = m.group(1)
            continue

        if line.startswith("ALTER TABLE"):
            buffered_statement = [line]
            if line.rstrip().endswith(";"):
                statement = "".join(buffered_statement)
                if "FOREIGN KEY" in statement:
                    skipped_counts["_foreign_key_constraints"] = (
                        skipped_counts.get("_foreign_key_constraints", 0) + 1
                    )
                else:
                    stdout.write(statement)
                buffered_statement = []
            continue

        stdout.write(line)

    return skipped_counts


def main():
    from src.tables import EXCLUDE_TABLES
    skipped = filter_stream(sys.stdin, sys.stdout, EXCLUDE_TABLES)
    for table, count in sorted(skipped.items(), key=lambda kv: -kv[1]):
        print(f"  skipped {count:>12,} rows from {table}", file=sys.stderr)


if __name__ == "__main__":
    main()
