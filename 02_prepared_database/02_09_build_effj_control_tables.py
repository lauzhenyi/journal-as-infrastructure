#!/usr/bin/env python3
"""Build EffJ timing and control variables for the retained analyses."""

from __future__ import annotations

import time

import duckdb


DATABASE_PATH = "/private/tmp/journal_structure_six.duckdb"
connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_story_robustness_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def replace_table(name: str, query: str) -> None:
    """Replace one persistent table and report its build time and size."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    rows = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {rows:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


replace_table(
    "robust_topic_exposure_six",
    """
    WITH annual AS (
        SELECT
            exposure.*,
            alternative.log_journal_count,
            alternative.journal_entropy,
            LN(alternative.entropy_effective_journals)
                AS log_entropy_effective_journals,
            SUM(POWER(counts.journal_papers, 2))
                / POWER(MAX(counts.topic_year_papers), 2)
                AS hhi_recomputed,
            MAX(counts.journal_share) AS top1_journal_share,
            SUM(counts.journal_share) FILTER (
                WHERE counts.journal_rank <= 5
            ) AS top5_journal_share,
            SUM(counts.journal_share) FILTER (
                WHERE counts.journal_rank <= 10
            ) AS top10_journal_share
        FROM journal_exposure AS exposure
        INNER JOIN journal_exposure_alternatives_six AS alternative USING (
            universe, analytic_field, publication_year, topic_id
        )
        INNER JOIN (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY universe, analytic_field,
                                 publication_year, topic_id
                    ORDER BY journal_papers DESC, source_id
                ) AS journal_rank
            FROM journal_topic_year_counts_six
        ) AS counts USING (
            universe, analytic_field, publication_year, topic_id
        )
        GROUP BY ALL
    )
    SELECT
        *,
        LAG(log_eff_j) OVER exposure_series AS lag1_log_eff_j,
        AVG(log_eff_j) OVER (
            exposure_series ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
        ) AS prior3_mean_log_eff_j,
        COUNT(log_eff_j) OVER (
            exposure_series ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
        ) AS prior3_years_available
    FROM annual
    WINDOW exposure_series AS (
        PARTITION BY universe, analytic_field, topic_id
        ORDER BY publication_year
    )
    """,
)
