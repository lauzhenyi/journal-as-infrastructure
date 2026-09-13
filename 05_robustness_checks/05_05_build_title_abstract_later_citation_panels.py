#!/usr/bin/env python3
"""Build text-only taxonomy robustness panels for cumulative handoff."""

from __future__ import annotations

import os
from pathlib import Path
import time

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/cumulative_handoff")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_text_handoff_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def build_table(name: str, query: str) -> None:
    """Replace a derived table and report its size and elapsed time."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    rows = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(f"Built {name}: {rows:,} rows in {time.time() - started:.1f}s")


build_table(
    "text_handoff_family_panel_six",
    """
    SELECT
        family.*,
        assignment.text_cluster_id,
        CONCAT(
            family.universe, '|', family.publication_year, '|',
            assignment.text_cluster_id
        ) AS text_cluster_year_id
    FROM cumulative_handoff_family_panel_six AS family
    INNER JOIN text_only_cluster_assignments_six AS assignment
      ON family.work_id = assignment.work_id
     AND family.publication_year = assignment.publication_year
    """,
)

build_table(
    "text_handoff_subfield_panel_six",
    """
    WITH scoped_late AS (
        SELECT
            article.universe,
            scope.scope_name,
            assignment.publication_year,
            assignment.text_cluster_id,
            status.pair_type,
            SUM(status.eligible_late_citers) AS eligible_late_citers,
            SUM(status.late_citers_with_handoff)
                AS late_citers_with_handoff,
            SUM(opportunity.possible_handoffs) AS possible_handoffs
        FROM cumulative_handoff_late_citer_status_six AS status
        INNER JOIN analysis_articles AS article
          ON status.universe = article.universe
         AND status.focal_work_id = article.work_id
        INNER JOIN text_only_cluster_assignments_six AS assignment
          ON article.work_id = assignment.work_id
         AND article.publication_year = assignment.publication_year
        INNER JOIN text_only_coordination_scope_six AS scope
          ON scope.scope_type = 'all'
          OR (scope.scope_type = 'field'
              AND assignment.analytic_field = scope.scope_field)
          OR (scope.scope_type = 'exclude'
              AND assignment.analytic_field <> scope.scope_field)
        INNER JOIN cumulative_handoff_opportunities_six AS opportunity
          ON status.universe = opportunity.universe
         AND status.focal_work_id = opportunity.focal_work_id
         AND status.pair_type = opportunity.pair_type
        GROUP BY article.universe, scope.scope_name,
                 assignment.publication_year,
                 assignment.text_cluster_id, status.pair_type
    ),
    early AS (
        SELECT
            universe,
            scope_name,
            publication_year,
            text_cluster_id,
            MAX(log_eff_j) AS log_eff_j,
            SUM(tie_count) FILTER (WHERE pair_type = 'cross') AS cross_ties,
            SUM(possible_pairs) FILTER (WHERE pair_type = 'cross')
                AS cross_possible_pairs,
            SUM(tie_count) FILTER (WHERE pair_type = 'within') AS within_ties,
            SUM(possible_pairs) FILTER (WHERE pair_type = 'within')
                AS within_possible_pairs
        FROM text_only_coordination_panel_six
        GROUP BY universe, scope_name, publication_year, text_cluster_id
    )
    SELECT
        late.*,
        early.log_eff_j,
        CONCAT(
            late.universe, '|', late.scope_name, '|',
            late.publication_year, '|', late.text_cluster_id
        ) AS panel_id,
        CONCAT(late.text_cluster_id, '|', late.pair_type)
            AS cluster_pair_id,
        CONCAT(late.publication_year, '|', late.pair_type)
            AS year_pair_id,
        CAST(late.pair_type = 'cross' AS INTEGER) AS is_cross,
        LN((early.cross_ties + 0.5) / (early.cross_possible_pairs + 1.0))
          - LN((early.within_ties + 0.5) / (early.within_possible_pairs + 1.0))
            AS early_coordination_gap,
        LN(late.eligible_late_citers) AS log_eligible_late_citers,
        LN(late.possible_handoffs / late.eligible_late_citers)
            AS log_early_options_per_late_citer
    FROM scoped_late AS late
    INNER JOIN early USING (
        universe, scope_name, publication_year, text_cluster_id
    )
    WHERE early.cross_possible_pairs > 0
      AND early.within_possible_pairs > 0
      AND late.eligible_late_citers > 0
    """,
)

connection.execute(
    f"COPY text_handoff_family_panel_six TO "
    f"'{OUTPUT_DIRECTORY / 'text_handoff_family_panel.parquet'}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)
connection.execute(
    f"COPY text_handoff_subfield_panel_six TO "
    f"'{OUTPUT_DIRECTORY / 'text_handoff_subfield_panel.parquet'}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)

connection.close()
