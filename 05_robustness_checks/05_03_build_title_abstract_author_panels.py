#!/usr/bin/env python3
"""Build the researcher-scale text-only taxonomy circularity audit."""

from __future__ import annotations

import os
from pathlib import Path
import time

import duckdb


DATABASE_PATH = os.environ.get(
    "JOURNAL_STRUCTURE_DATABASE",
    "/private/tmp/journal_structure_six.duckdb",
)
OUTPUT_DIRECTORY = Path("results/direct_outcome_gap")
OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_text_researcher_audit_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def build_table(name: str, query: str) -> None:
    """Replace a derived table and report build time and row count."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    row_count = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {row_count:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


build_table(
    "text_only_researcher_coordination_six",
    """
    WITH family AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            assignment.text_cluster_id,
            opportunity.within_possible_pairs,
            opportunity.cross_possible_pairs,
            COALESCE(realized.within_ties, 0) AS within_ties,
            COALESCE(realized.cross_ties, 0) AS cross_ties
        FROM researcher_attention_cohort_six AS cohort
        INNER JOIN text_only_cluster_assignments_six AS assignment
          ON cohort.focal_work_id = assignment.work_id
        INNER JOIN temporal_coordination_opportunities_six AS opportunity
          ON cohort.universe = opportunity.universe
         AND cohort.focal_work_id = opportunity.focal_work_id
        LEFT JOIN temporal_coordination_realized_six AS realized
          ON cohort.universe = realized.universe
         AND cohort.focal_work_id = realized.focal_work_id
    ),
    portfolio AS (
        SELECT
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year,
            COUNT(DISTINCT text_cluster_id) AS focal_text_cluster_count,
            ANY_VALUE(text_cluster_id) AS text_cluster_id,
            COUNT(*) AS focal_families,
            SUM(within_possible_pairs) AS within_possible_pairs,
            SUM(cross_possible_pairs) AS cross_possible_pairs,
            SUM(within_ties) AS within_ties,
            SUM(cross_ties) AS cross_ties
        FROM family
        GROUP BY
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year
    ),
    exposed AS (
        SELECT
            portfolio.*,
            scope.scope_name,
            exposure.log_eff_j,
            CONCAT(
                portfolio.analytic_field,
                '_',
                portfolio.cohort_year
            ) AS field_year_id
        FROM portfolio
        INNER JOIN text_only_coordination_scope_six AS scope
          ON scope.scope_name = 'pooled'
          OR (
              scope.scope_type = 'field'
              AND portfolio.analytic_field = scope.scope_field
          )
          OR (
              scope.scope_type = 'exclude'
              AND portfolio.analytic_field <> scope.scope_field
          )
        INNER JOIN text_only_cluster_exposure_six AS exposure
          ON portfolio.universe = exposure.universe
         AND scope.scope_name = exposure.scope_name
         AND portfolio.cohort_year = exposure.publication_year
         AND portfolio.text_cluster_id = exposure.text_cluster_id
        WHERE portfolio.focal_text_cluster_count = 1
          AND portfolio.within_possible_pairs > 0
          AND portfolio.cross_possible_pairs > 0
    ),
    eligible AS (
        SELECT ROW_NUMBER() OVER () AS panel_id, *
        FROM exposed
    )
    SELECT
        panel_id,
        universe,
        scope_name,
        author_id,
        institution_id,
        analytic_field,
        cohort_year,
        field_year_id,
        text_cluster_id,
        focal_families,
        log_eff_j,
        0 AS is_cross_journal,
        'within' AS pair_type,
        within_ties AS tie_count,
        within_possible_pairs AS possible_pairs
    FROM eligible
    UNION ALL
    SELECT
        panel_id,
        universe,
        scope_name,
        author_id,
        institution_id,
        analytic_field,
        cohort_year,
        field_year_id,
        text_cluster_id,
        focal_families,
        log_eff_j,
        1 AS is_cross_journal,
        'cross' AS pair_type,
        cross_ties AS tie_count,
        cross_possible_pairs AS possible_pairs
    FROM eligible
    """,
)

output_path = OUTPUT_DIRECTORY / "text_only_researcher_coordination.parquet"
connection.execute(
    f"""
    COPY text_only_researcher_coordination_six
    TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

violations = connection.execute(
    """
    SELECT COUNT(*)
    FROM text_only_researcher_coordination_six
    WHERE tie_count > possible_pairs
    """
).fetchone()[0]
if violations:
    raise RuntimeError(f"Found {violations:,} cells with impossible tie counts")

print(
    connection.execute(
        """
        SELECT
            universe,
            scope_name,
            pair_type,
            COUNT(*) AS researcher_panels,
            SUM(focal_families) AS focal_families,
            SUM(tie_count) AS ties,
            SUM(possible_pairs) AS possible_pairs,
            1000.0 * SUM(tie_count) / SUM(possible_pairs)
                AS ties_per_1000_opportunities
        FROM text_only_researcher_coordination_six
        GROUP BY universe, scope_name, pair_type
        ORDER BY universe, scope_name, pair_type
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

connection.close()
