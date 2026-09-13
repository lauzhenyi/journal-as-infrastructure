#!/usr/bin/env python3
"""Build journal-count and entropy alternatives to EffJ."""

from __future__ import annotations

import time

import duckdb


connection = duckdb.connect("/private/tmp/journal_structure_six.duckdb")
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_alt_exposure_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


started = time.time()
connection.execute(
    """
    CREATE OR REPLACE TABLE journal_exposure_alternatives_six AS
    WITH journal_counts AS (
        SELECT universe, analytic_field, publication_year, topic_id,
               source_id, COUNT(*) AS journal_articles
        FROM paper_universes
        GROUP BY ALL
    ),
    shares AS (
        SELECT *, journal_articles * 1.0 /
            SUM(journal_articles) OVER cell AS journal_share
        FROM journal_counts
        WINDOW cell AS (
            PARTITION BY universe, analytic_field, publication_year, topic_id
        )
    )
    SELECT universe, analytic_field, publication_year, topic_id,
           COUNT(*) AS journal_count,
           LN(COUNT(*)) AS log_journal_count,
           -SUM(journal_share * LN(journal_share)) AS journal_entropy,
           EXP(-SUM(journal_share * LN(journal_share)))
               AS entropy_effective_journals
    FROM shares
    GROUP BY universe, analytic_field, publication_year, topic_id
    """
)
print(
    "Built journal_exposure_alternatives_six in "
    f"{time.time() - started:.1f}s",
    flush=True,
)
