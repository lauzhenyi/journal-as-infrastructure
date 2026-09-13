#!/usr/bin/env python3
"""Build journal counts within topic-year cells."""

from __future__ import annotations

import time

import duckdb


DATABASE_PATH = "/private/tmp/journal_structure_six.duckdb"
connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_entry_exit_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


def replace_table(name: str, query: str) -> None:
    """Replace a table and report its row count and build time."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    row_count = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {row_count:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


replace_table(
    "journal_topic_year_counts_six",
    """
    WITH counts AS (
        SELECT
            universe,
            analytic_field,
            topic_id,
            publication_year,
            source_id,
            COUNT(*) AS journal_papers
        FROM paper_universes
        WHERE publication_year BETWEEN 2016 AND 2023
          AND source_id IS NOT NULL
        GROUP BY ALL
    )
    SELECT
        *,
        SUM(journal_papers) OVER (
            PARTITION BY universe, topic_id, publication_year
        ) AS topic_year_papers,
        journal_papers * 1.0 / SUM(journal_papers) OVER (
            PARTITION BY universe, topic_id, publication_year
        ) AS journal_share
    FROM counts
    """,
)
