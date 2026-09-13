#!/usr/bin/env python3
"""Build temporally ordered cumulative-knowledge handoff panels."""

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
    "SET temp_directory='/private/tmp/duckdb_cumulative_handoff_tmp'"
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
    "cumulative_handoff_early_members_six",
    """
    SELECT member.*
    FROM temporal_coordination_members_six AS member
    INNER JOIN analysis_articles AS article
      ON member.universe = article.universe
     AND member.focal_work_id = article.work_id
    WHERE article.publication_year BETWEEN 2015 AND 2021
    """,
)

build_table(
    "cumulative_handoff_late_members_six",
    """
    SELECT DISTINCT
        family.universe,
        family.focal_work_id,
        family.citing_work_id,
        family.citing_date,
        family.citing_source_id
    FROM conversation_family_horizon_six AS family
    INNER JOIN (
        SELECT DISTINCT universe, focal_work_id
        FROM cumulative_handoff_early_members_six
    ) AS eligible_family
      ON family.universe = eligible_family.universe
     AND family.focal_work_id = eligible_family.focal_work_id
    WHERE family.horizon = 5
      AND family.citing_year - family.focal_year BETWEEN 3 AND 4
      AND family.citing_date IS NOT NULL
      AND family.citing_source_id IS NOT NULL
      AND (
          EXTRACT(month FROM family.citing_date) <> 1
          OR EXTRACT(day FROM family.citing_date) <> 1
      )
    """,
)

build_table(
    "cumulative_handoff_early_visibility_six",
    """
    SELECT
        early.universe,
        early.focal_work_id,
        SUM(COALESCE(LIST_SUM(LIST_TRANSFORM(
            work.citation_counts_by_year,
            citation -> CASE
                WHEN citation.year <= focal.publication_year + 2
                    THEN citation.cited_by_count
                ELSE 0
            END
        )), 0)) AS early_member_prior_citations,
        MAX(COALESCE(LIST_SUM(LIST_TRANSFORM(
            work.citation_counts_by_year,
            citation -> CASE
                WHEN citation.year <= focal.publication_year + 2
                    THEN citation.cited_by_count
                ELSE 0
            END
        )), 0)) AS max_early_member_prior_citations
    FROM cumulative_handoff_early_members_six AS early
    INNER JOIN analysis_articles AS focal
      ON early.universe = focal.universe
     AND early.focal_work_id = focal.work_id
    INNER JOIN read_parquet(
        '/Volumes/Extreme SSD/openalex_20260203/analytic_work/*.parquet'
    ) AS work
      ON early.citing_work_id = work.work_id
    GROUP BY early.universe, early.focal_work_id
    """,
)

build_table(
    "cumulative_handoff_opportunities_six",
    """
    SELECT
        late.universe,
        late.focal_work_id,
        CASE
            WHEN late.citing_source_id = early.citing_source_id
                THEN 'within'
            ELSE 'cross'
        END AS pair_type,
        COUNT(*) AS possible_handoffs
    FROM cumulative_handoff_late_members_six AS late
    INNER JOIN cumulative_handoff_early_members_six AS early
      ON late.universe = early.universe
     AND late.focal_work_id = early.focal_work_id
    GROUP BY late.universe, late.focal_work_id, pair_type
    """,
)

build_table(
    "cumulative_handoff_realized_six",
    """
    SELECT
        pair.universe,
        pair.focal_work_id,
        CASE
            WHEN late.citing_source_id = early.citing_source_id
                THEN 'within'
            ELSE 'cross'
        END AS pair_type,
        COUNT(*) AS realized_handoffs
    FROM conversation_pair_horizon_six AS pair
    INNER JOIN cumulative_handoff_late_members_six AS late
      ON pair.universe = late.universe
     AND pair.focal_work_id = late.focal_work_id
     AND pair.later_work_id = late.citing_work_id
    INNER JOIN cumulative_handoff_early_members_six AS early
      ON pair.universe = early.universe
     AND pair.focal_work_id = early.focal_work_id
     AND pair.earlier_work_id = early.citing_work_id
    WHERE pair.horizon = 5
    GROUP BY pair.universe, pair.focal_work_id, pair_type
    """,
)

build_table(
    "cumulative_handoff_realized_late_citers_six",
    """
    SELECT DISTINCT
        pair.universe,
        pair.focal_work_id,
        pair.later_work_id,
        CASE
            WHEN late.citing_source_id = early.citing_source_id
                THEN 'within'
            ELSE 'cross'
        END AS pair_type
    FROM conversation_pair_horizon_six AS pair
    INNER JOIN cumulative_handoff_late_members_six AS late
      ON pair.universe = late.universe
     AND pair.focal_work_id = late.focal_work_id
     AND pair.later_work_id = late.citing_work_id
    INNER JOIN cumulative_handoff_early_members_six AS early
      ON pair.universe = early.universe
     AND pair.focal_work_id = early.focal_work_id
     AND pair.earlier_work_id = early.citing_work_id
    WHERE pair.horizon = 5
    """,
)

build_table(
    "cumulative_handoff_late_citer_status_six",
    """
    WITH eligible AS (
        SELECT DISTINCT
            late.universe,
            late.focal_work_id,
            late.citing_work_id AS later_work_id,
            CASE
                WHEN late.citing_source_id = early.citing_source_id
                    THEN 'within'
                ELSE 'cross'
            END AS pair_type
        FROM cumulative_handoff_late_members_six AS late
        INNER JOIN cumulative_handoff_early_members_six AS early
          ON late.universe = early.universe
         AND late.focal_work_id = early.focal_work_id
    )
    SELECT
        eligible.universe,
        eligible.focal_work_id,
        eligible.pair_type,
        COUNT(*) AS eligible_late_citers,
        COUNT(realized.later_work_id) AS late_citers_with_handoff
    FROM eligible
    LEFT JOIN cumulative_handoff_realized_late_citers_six AS realized USING (
        universe, focal_work_id, later_work_id, pair_type
    )
    GROUP BY eligible.universe, eligible.focal_work_id, eligible.pair_type
    """,
)

build_table(
    "cumulative_handoff_family_panel_six",
    """
    WITH handoff AS (
        SELECT
            opportunity.universe,
            opportunity.focal_work_id,
            SUM(opportunity.possible_handoffs) AS possible_handoffs,
            SUM(COALESCE(realized.realized_handoffs, 0)) AS realized_handoffs,
            SUM(opportunity.possible_handoffs) FILTER (
                WHERE opportunity.pair_type = 'cross'
            ) AS cross_possible_handoffs,
            SUM(COALESCE(realized.realized_handoffs, 0)) FILTER (
                WHERE opportunity.pair_type = 'cross'
            ) AS cross_realized_handoffs,
            SUM(opportunity.possible_handoffs) FILTER (
                WHERE opportunity.pair_type = 'within'
            ) AS within_possible_handoffs,
            SUM(COALESCE(realized.realized_handoffs, 0)) FILTER (
                WHERE opportunity.pair_type = 'within'
            ) AS within_realized_handoffs
        FROM cumulative_handoff_opportunities_six AS opportunity
        LEFT JOIN cumulative_handoff_realized_six AS realized
          ON opportunity.universe = realized.universe
         AND opportunity.focal_work_id = realized.focal_work_id
         AND opportunity.pair_type = realized.pair_type
        GROUP BY opportunity.universe, opportunity.focal_work_id
    ),
    member_counts AS (
        SELECT
            early.universe,
            early.focal_work_id,
            COUNT(DISTINCT early.citing_work_id) AS early_member_count,
            COUNT(DISTINCT late.citing_work_id) AS late_member_count
        FROM cumulative_handoff_early_members_six AS early
        INNER JOIN cumulative_handoff_late_members_six AS late
          ON early.universe = late.universe
         AND early.focal_work_id = late.focal_work_id
        GROUP BY early.universe, early.focal_work_id
    ),
    late_citer_outcome AS (
        SELECT
            late.universe,
            late.focal_work_id,
            COUNT(DISTINCT late.citing_work_id) AS eligible_late_citers,
            COUNT(DISTINCT realized.later_work_id)
                AS late_citers_with_handoff
        FROM cumulative_handoff_late_members_six AS late
        LEFT JOIN cumulative_handoff_realized_late_citers_six AS realized
          ON late.universe = realized.universe
         AND late.focal_work_id = realized.focal_work_id
         AND late.citing_work_id = realized.later_work_id
        GROUP BY late.universe, late.focal_work_id
    )
    SELECT
        article.universe,
        article.work_id,
        article.analytic_field,
        article.publication_year,
        article.topic_id,
        CONCAT(
            article.universe, '|', article.analytic_field, '|',
            article.publication_year, '|', article.topic_id
        ) AS topic_year_id,
        article.corresponding_author_id,
        article.corresponding_institution_id,
        article.citations_3y,
        article.log_eff_j,
        LN(article.cell_n) AS log_cell_n,
        article.field_year_id,
        article.log_authors,
        article.oa_value,
        member_counts.early_member_count,
        member_counts.late_member_count,
        late_citer_outcome.eligible_late_citers,
        late_citer_outcome.late_citers_with_handoff,
        visibility.early_member_prior_citations,
        visibility.max_early_member_prior_citations,
        LN(1 + visibility.early_member_prior_citations)
            AS log_early_member_prior_citations,
        LN(1 + visibility.max_early_member_prior_citations)
            AS log_max_early_member_prior_citations,
        handoff.* EXCLUDE (universe, focal_work_id),
        early_opportunity.cross_possible_pairs,
        early_opportunity.within_possible_pairs,
        COALESCE(early_realized.cross_ties, 0) AS early_cross_ties,
        COALESCE(early_realized.within_ties, 0) AS early_within_ties,
        LN(
            (COALESCE(early_realized.cross_ties, 0) + 0.5)
            / (early_opportunity.cross_possible_pairs + 1.0)
        ) AS log_early_cross_rate,
        LN(
            (COALESCE(early_realized.within_ties, 0) + 0.5)
            / (early_opportunity.within_possible_pairs + 1.0)
        ) AS log_early_within_rate,
        LN(early_opportunity.cross_possible_pairs
            + early_opportunity.within_possible_pairs) AS log_early_opportunities,
        LN(handoff.possible_handoffs) AS log_handoff_opportunities
    FROM handoff
    INNER JOIN analysis_articles AS article
      ON handoff.universe = article.universe
     AND handoff.focal_work_id = article.work_id
    INNER JOIN member_counts
      ON handoff.universe = member_counts.universe
     AND handoff.focal_work_id = member_counts.focal_work_id
    INNER JOIN late_citer_outcome
      ON handoff.universe = late_citer_outcome.universe
     AND handoff.focal_work_id = late_citer_outcome.focal_work_id
    INNER JOIN cumulative_handoff_early_visibility_six AS visibility
      ON handoff.universe = visibility.universe
     AND handoff.focal_work_id = visibility.focal_work_id
    INNER JOIN temporal_coordination_opportunities_six AS early_opportunity
      ON handoff.universe = early_opportunity.universe
     AND handoff.focal_work_id = early_opportunity.focal_work_id
    LEFT JOIN temporal_coordination_realized_six AS early_realized
      ON handoff.universe = early_realized.universe
     AND handoff.focal_work_id = early_realized.focal_work_id
    WHERE article.corresponding_author_id IS NOT NULL
      AND article.corresponding_institution_id IS NOT NULL
      AND early_opportunity.cross_possible_pairs > 0
      AND early_opportunity.within_possible_pairs > 0
      AND handoff.possible_handoffs > 0
    """,
)

build_table(
    "cumulative_handoff_subfield_panel_six",
    """
    WITH late_handoff AS (
        SELECT
            article.universe,
            article.analytic_field,
            article.publication_year,
            article.topic_id,
            status.pair_type,
            SUM(status.eligible_late_citers) AS eligible_late_citers,
            SUM(status.late_citers_with_handoff)
                AS late_citers_with_handoff,
            SUM(opportunity.possible_handoffs) AS possible_handoffs
        FROM cumulative_handoff_late_citer_status_six AS status
        INNER JOIN analysis_articles AS article
          ON status.universe = article.universe
         AND status.focal_work_id = article.work_id
        INNER JOIN cumulative_handoff_opportunities_six AS opportunity
          ON status.universe = opportunity.universe
         AND status.focal_work_id = opportunity.focal_work_id
         AND status.pair_type = opportunity.pair_type
        GROUP BY article.universe, article.analytic_field,
                 article.publication_year, article.topic_id,
                 status.pair_type
    ),
    early_coordination AS (
        SELECT
            universe,
            analytic_field,
            publication_year,
            topic_id,
            ANY_VALUE(field_year_id) AS field_year_id,
            ANY_VALUE(log_eff_j) AS log_eff_j,
            ANY_VALUE(log_cell_n) AS log_cell_n,
            ANY_VALUE(top1_journal_share) AS top1_journal_share,
            ANY_VALUE(oa_share) AS oa_share,
            ANY_VALUE(mean_log_authors) AS mean_log_authors,
            ANY_VALUE(mean_log_sjr) AS mean_log_sjr,
            SUM(tie_count) FILTER (WHERE pair_type = 'cross') AS cross_ties,
            SUM(possible_pairs) FILTER (WHERE pair_type = 'cross')
                AS cross_possible_pairs,
            SUM(tie_count) FILTER (WHERE pair_type = 'within') AS within_ties,
            SUM(possible_pairs) FILTER (WHERE pair_type = 'within')
                AS within_possible_pairs
        FROM temporal_coordination_topic_year_six
        WHERE publication_year BETWEEN 2015 AND 2021
        GROUP BY universe, analytic_field, publication_year, topic_id
    )
    SELECT
        late_handoff.*,
        early_coordination.field_year_id,
        early_coordination.log_eff_j,
        early_coordination.log_cell_n,
        early_coordination.top1_journal_share,
        early_coordination.oa_share,
        early_coordination.mean_log_authors,
        early_coordination.mean_log_sjr,
        CONCAT(
            late_handoff.universe, '|', late_handoff.analytic_field, '|',
            late_handoff.publication_year, '|', late_handoff.topic_id
        ) AS topic_year_id,
        CONCAT(late_handoff.topic_id, '|', late_handoff.pair_type)
            AS topic_pair_id,
        CONCAT(early_coordination.field_year_id, '|', late_handoff.pair_type)
            AS field_year_pair_id,
        CAST(late_handoff.pair_type = 'cross' AS INTEGER) AS is_cross,
        LN(
            (early_coordination.cross_ties + 0.5)
            / (early_coordination.cross_possible_pairs + 1.0)
        ) - LN(
            (early_coordination.within_ties + 0.5)
            / (early_coordination.within_possible_pairs + 1.0)
        ) AS early_coordination_gap,
        LN(late_handoff.eligible_late_citers) AS log_eligible_late_citers
        , LN(
            late_handoff.possible_handoffs
            / late_handoff.eligible_late_citers
        ) AS log_early_options_per_late_citer
    FROM late_handoff
    INNER JOIN early_coordination USING (
        universe, analytic_field, publication_year, topic_id
    )
    WHERE early_coordination.cross_possible_pairs > 0
      AND early_coordination.within_possible_pairs > 0
      AND late_handoff.eligible_late_citers > 0
    """,
)

family_path = OUTPUT_DIRECTORY / "cumulative_handoff_family_panel.parquet"
subfield_path = OUTPUT_DIRECTORY / "cumulative_handoff_subfield_panel.parquet"
connection.execute(
    f"COPY cumulative_handoff_family_panel_six TO '{family_path}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)
connection.execute(
    f"COPY cumulative_handoff_subfield_panel_six TO '{subfield_path}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)

audit = connection.execute(
    """
    SELECT
        universe,
        COUNT(*) AS focal_works,
        SUM(realized_handoffs) AS realized_handoffs,
        SUM(possible_handoffs) AS possible_handoffs,
        1000.0 * SUM(realized_handoffs) / SUM(possible_handoffs)
            AS handoffs_per_1000_opportunities,
        COUNT(*) FILTER (
            WHERE realized_handoffs > possible_handoffs
        ) AS impossible_cases
    FROM cumulative_handoff_family_panel_six
    GROUP BY universe
    ORDER BY universe
    """
).fetchdf()
print(audit.to_string(index=False), flush=True)

connection.close()
