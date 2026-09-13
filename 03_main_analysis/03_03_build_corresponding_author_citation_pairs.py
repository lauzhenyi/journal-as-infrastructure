#!/usr/bin/env python3
"""Build temporally eligible coordination outcomes for researcher portfolios."""

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
    "SET temp_directory='/private/tmp/duckdb_temporal_researcher_tmp'"
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
    "temporal_researcher_coordination_six",
    """
    WITH family AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            cohort.field_year_id,
            cohort.topic_id,
            cohort.focal_work_id,
            opportunity.within_possible_pairs,
            opportunity.cross_possible_pairs,
            COALESCE(realized.within_ties, 0) AS within_ties,
            COALESCE(realized.cross_ties, 0) AS cross_ties
        FROM researcher_attention_cohort_six AS cohort
        INNER JOIN temporal_coordination_opportunities_six AS opportunity
          ON cohort.universe = opportunity.universe
         AND cohort.focal_work_id = opportunity.focal_work_id
        LEFT JOIN temporal_coordination_realized_six AS realized
          ON cohort.universe = realized.universe
         AND cohort.focal_work_id = realized.focal_work_id
        WHERE cohort.cell_n >= 20
    ),
    panel AS (
        SELECT
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year,
            ANY_VALUE(field_year_id) AS field_year_id,
            COUNT(DISTINCT topic_id) AS focal_topic_count,
            ANY_VALUE(topic_id) AS topic_id,
            COUNT(*) AS focal_families,
            SUM(within_possible_pairs) AS within_possible_pairs,
            SUM(cross_possible_pairs) AS cross_possible_pairs,
            SUM(within_ties) AS within_ties,
            SUM(cross_ties) AS cross_ties
        FROM family
        GROUP BY universe, author_id, institution_id,
                 analytic_field, cohort_year
    ),
    topic_context AS (
        SELECT
            article.universe,
            article.analytic_field,
            article.publication_year,
            article.topic_id,
            AVG(article.oa_value) AS oa_share,
            AVG(article.log_authors) AS mean_log_authors,
            AVG(LN(annual_sjr.sjr)) FILTER (
                WHERE annual_sjr.sjr > 0
            ) AS mean_log_sjr
        FROM analysis_articles AS article
        LEFT JOIN scimago_annual_sjr_source_six AS annual_sjr
          ON article.source_id = annual_sjr.source_id
         AND article.publication_year = annual_sjr.year
        GROUP BY article.universe, article.analytic_field,
                 article.publication_year, article.topic_id
    ),
    topic_year AS (
        SELECT
            exposure.universe,
            exposure.analytic_field,
            exposure.publication_year,
            exposure.topic_id,
            exposure.log_eff_j,
            LN(exposure.cell_n) AS log_cell_n,
            exposure.top1_journal_share,
            context.oa_share,
            context.mean_log_authors,
            context.mean_log_sjr
        FROM robust_topic_exposure_six AS exposure
        INNER JOIN topic_context AS context USING (
            universe, analytic_field, publication_year, topic_id
        )
        WHERE exposure.cell_n >= 20
    ),
    exposed AS (
        SELECT
            panel.*,
            current_exposure.log_eff_j,
            current_exposure.log_cell_n,
            current_exposure.top1_journal_share,
            current_exposure.oa_share,
            current_exposure.mean_log_authors,
            current_exposure.mean_log_sjr,
            lagged_exposure.log_eff_j AS lag1_log_eff_j,
            future_exposure.log_eff_j AS lead1_log_eff_j
        FROM panel
        INNER JOIN topic_year AS current_exposure
          ON panel.universe = current_exposure.universe
         AND panel.analytic_field = current_exposure.analytic_field
         AND panel.cohort_year = current_exposure.publication_year
         AND panel.topic_id = current_exposure.topic_id
        LEFT JOIN topic_year AS lagged_exposure
          ON panel.universe = lagged_exposure.universe
         AND panel.analytic_field = lagged_exposure.analytic_field
         AND panel.cohort_year - 1 = lagged_exposure.publication_year
         AND panel.topic_id = lagged_exposure.topic_id
        LEFT JOIN topic_year AS future_exposure
          ON panel.universe = future_exposure.universe
         AND panel.analytic_field = future_exposure.analytic_field
         AND panel.cohort_year + 1 = future_exposure.publication_year
         AND panel.topic_id = future_exposure.topic_id
        WHERE panel.focal_topic_count = 1
          AND panel.within_possible_pairs > 0
          AND panel.cross_possible_pairs > 0
    ),
    eligible AS (
        SELECT ROW_NUMBER() OVER () AS panel_id, *
        FROM exposed
    )
    SELECT
        panel_id,
        universe,
        author_id,
        institution_id,
        analytic_field,
        cohort_year,
        field_year_id,
        topic_id,
        focal_families,
        log_eff_j,
        log_cell_n,
        top1_journal_share,
        oa_share,
        mean_log_authors,
        mean_log_sjr,
        lag1_log_eff_j,
        lead1_log_eff_j,
        0 AS is_cross_journal,
        'within' AS pair_type,
        within_ties AS tie_count,
        within_possible_pairs AS possible_pairs
    FROM eligible
    UNION ALL
    SELECT
        panel_id,
        universe,
        author_id,
        institution_id,
        analytic_field,
        cohort_year,
        field_year_id,
        topic_id,
        focal_families,
        log_eff_j,
        log_cell_n,
        top1_journal_share,
        oa_share,
        mean_log_authors,
        mean_log_sjr,
        lag1_log_eff_j,
        lead1_log_eff_j,
        1 AS is_cross_journal,
        'cross' AS pair_type,
        cross_ties AS tie_count,
        cross_possible_pairs AS possible_pairs
    FROM eligible
    """,
)

output_path = OUTPUT_DIRECTORY / "temporal_researcher_coordination.parquet"
connection.execute(
    f"""
    COPY temporal_researcher_coordination_six
    TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

violation_count = connection.execute(
    """
    SELECT COUNT(*)
    FROM temporal_researcher_coordination_six
    WHERE tie_count > possible_pairs
    """
).fetchone()[0]
if violation_count:
    raise RuntimeError(
        f"Found {violation_count:,} researcher panels with impossible tie counts"
    )

print(
    connection.execute(
        """
        SELECT
            universe,
            analytic_field,
            pair_type,
            COUNT(*) AS researcher_panels,
            SUM(focal_families) AS focal_families,
            SUM(tie_count) AS ties,
            SUM(possible_pairs) AS possible_pairs,
            1000.0 * SUM(tie_count) / SUM(possible_pairs)
                AS ties_per_1000_opportunities
        FROM temporal_researcher_coordination_six
        GROUP BY universe, analytic_field, pair_type
        ORDER BY universe, analytic_field, pair_type
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)
