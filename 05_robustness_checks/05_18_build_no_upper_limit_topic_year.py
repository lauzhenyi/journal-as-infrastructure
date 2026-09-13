#!/usr/bin/env python3
"""Build the no-upper-limit topic-year coordination sensitivity panel."""

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

if not Path(DATABASE_PATH).is_file():
    raise FileNotFoundError(
        f"Prepared DuckDB not found: {DATABASE_PATH}. "
        "Set JOURNAL_STRUCTURE_DATABASE to its current location."
    )

connection = duckdb.connect(DATABASE_PATH)
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute(
    "SET temp_directory='/private/tmp/duckdb_no_upper_limit_coordination_tmp'"
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
    "no_upper_limit_temporal_coordination_members_six",
    """
    WITH clean AS (
        SELECT
            universe,
            focal_work_id,
            citing_work_id,
            citing_date,
            citing_source_id,
            COUNT(*) OVER (
                PARTITION BY universe, focal_work_id
            ) AS clean_family_size
        FROM conversation_family_horizon_six
        WHERE horizon = 3
          AND citing_date IS NOT NULL
          AND citing_source_id IS NOT NULL
          AND (
              EXTRACT(month FROM citing_date) <> 1
              OR EXTRACT(day FROM citing_date) <> 1
          )
    )
    SELECT *
    FROM clean
    WHERE clean_family_size >= 2
    """,
)

build_table(
    "no_upper_limit_temporal_coordination_opportunities_six",
    """
    WITH family_date_counts AS (
        SELECT
            universe,
            focal_work_id,
            ANY_VALUE(clean_family_size) AS family_size,
            citing_date,
            COUNT(*) AS date_count
        FROM no_upper_limit_temporal_coordination_members_six
        GROUP BY universe, focal_work_id, citing_date
    ),
    total_pairs AS (
        SELECT
            universe,
            focal_work_id,
            ANY_VALUE(family_size) * (ANY_VALUE(family_size) - 1) / 2
              - SUM(date_count * (date_count - 1) / 2) AS total_possible_pairs
        FROM family_date_counts
        GROUP BY universe, focal_work_id
    ),
    source_date_counts AS (
        SELECT
            universe,
            focal_work_id,
            citing_source_id,
            citing_date,
            COUNT(*) AS source_date_count
        FROM no_upper_limit_temporal_coordination_members_six
        GROUP BY universe, focal_work_id, citing_source_id, citing_date
    ),
    source_counts AS (
        SELECT
            universe,
            focal_work_id,
            citing_source_id,
            SUM(source_date_count) AS source_count,
            SUM(source_date_count * (source_date_count - 1) / 2)
                AS tied_date_pairs
        FROM source_date_counts
        GROUP BY universe, focal_work_id, citing_source_id
    ),
    within_pairs AS (
        SELECT
            universe,
            focal_work_id,
            SUM(source_count * (source_count - 1) / 2 - tied_date_pairs)
                AS within_possible_pairs
        FROM source_counts
        GROUP BY universe, focal_work_id
    )
    SELECT
        total.universe,
        total.focal_work_id,
        within_pair.within_possible_pairs,
        total.total_possible_pairs - within_pair.within_possible_pairs
            AS cross_possible_pairs
    FROM total_pairs AS total
    INNER JOIN within_pairs AS within_pair USING (universe, focal_work_id)
    """,
)

build_table(
    "no_upper_limit_temporal_coordination_realized_six",
    """
    SELECT
        pair.universe,
        pair.focal_work_id,
        COUNT(*) FILTER (
            WHERE later.citing_source_id = earlier.citing_source_id
        ) AS within_ties,
        COUNT(*) FILTER (
            WHERE later.citing_source_id <> earlier.citing_source_id
        ) AS cross_ties
    FROM conversation_pair_horizon_six AS pair
    INNER JOIN no_upper_limit_temporal_coordination_members_six AS later
      ON pair.universe = later.universe
     AND pair.focal_work_id = later.focal_work_id
     AND pair.later_work_id = later.citing_work_id
    INNER JOIN no_upper_limit_temporal_coordination_members_six AS earlier
      ON pair.universe = earlier.universe
     AND pair.focal_work_id = earlier.focal_work_id
     AND pair.earlier_work_id = earlier.citing_work_id
    WHERE pair.horizon = 3
      AND later.citing_date > earlier.citing_date
    GROUP BY pair.universe, pair.focal_work_id
    """,
)

build_table(
    "no_upper_limit_temporal_coordination_topic_year_six",
    """
    WITH topic_context AS (
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
    family AS (
        SELECT
            article.universe,
            article.analytic_field,
            article.publication_year,
            article.topic_id,
            article.log_eff_j,
            article.field_year_id,
            LN(article.cell_n) AS log_cell_n,
            exposure.top1_journal_share,
            context.oa_share,
            context.mean_log_authors,
            context.mean_log_sjr,
            opportunity.focal_work_id,
            opportunity.within_possible_pairs,
            opportunity.cross_possible_pairs,
            COALESCE(realized.within_ties, 0) AS within_ties,
            COALESCE(realized.cross_ties, 0) AS cross_ties
        FROM no_upper_limit_temporal_coordination_opportunities_six AS opportunity
        INNER JOIN analysis_articles AS article
          ON opportunity.universe = article.universe
         AND opportunity.focal_work_id = article.work_id
        INNER JOIN robust_topic_exposure_six AS exposure
          ON article.universe = exposure.universe
         AND article.analytic_field = exposure.analytic_field
         AND article.publication_year = exposure.publication_year
         AND article.topic_id = exposure.topic_id
        INNER JOIN topic_context AS context
          ON article.universe = context.universe
         AND article.analytic_field = context.analytic_field
         AND article.publication_year = context.publication_year
         AND article.topic_id = context.topic_id
        LEFT JOIN no_upper_limit_temporal_coordination_realized_six AS realized
          ON opportunity.universe = realized.universe
         AND opportunity.focal_work_id = realized.focal_work_id
        WHERE article.cell_n >= 20
    ),
    aggregated AS (
        SELECT
            universe,
            analytic_field,
            publication_year,
            topic_id,
            field_year_id,
            ANY_VALUE(log_eff_j) AS log_eff_j,
            ANY_VALUE(log_cell_n) AS log_cell_n,
            ANY_VALUE(top1_journal_share) AS top1_journal_share,
            ANY_VALUE(oa_share) AS oa_share,
            ANY_VALUE(mean_log_authors) AS mean_log_authors,
            ANY_VALUE(mean_log_sjr) AS mean_log_sjr,
            COUNT(*) AS focal_families,
            SUM(within_possible_pairs) AS within_possible_pairs,
            SUM(cross_possible_pairs) AS cross_possible_pairs,
            SUM(within_ties) AS within_ties,
            SUM(cross_ties) AS cross_ties
        FROM family
        GROUP BY universe, analytic_field, publication_year,
                 topic_id, field_year_id
    ),
    eligible AS (
        SELECT
            ROW_NUMBER() OVER () AS panel_id,
            *
        FROM aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
    )
    SELECT
        panel_id,
        universe,
        analytic_field,
        publication_year,
        topic_id,
        field_year_id,
        log_eff_j,
        log_cell_n,
        top1_journal_share,
        oa_share,
        mean_log_authors,
        mean_log_sjr,
        focal_families,
        0 AS is_cross_journal,
        'within' AS pair_type,
        within_ties AS tie_count,
        within_possible_pairs AS possible_pairs
    FROM eligible
    UNION ALL
    SELECT
        panel_id,
        universe,
        analytic_field,
        publication_year,
        topic_id,
        field_year_id,
        log_eff_j,
        log_cell_n,
        top1_journal_share,
        oa_share,
        mean_log_authors,
        mean_log_sjr,
        focal_families,
        1 AS is_cross_journal,
        'cross' AS pair_type,
        cross_ties AS tie_count,
        cross_possible_pairs AS possible_pairs
    FROM eligible
    """,
)

output_path = OUTPUT_DIRECTORY / "no_upper_limit_temporal_coordination_topic_year.parquet"

violation_count = connection.execute(
    """
    SELECT COUNT(*)
    FROM no_upper_limit_temporal_coordination_topic_year_six
    WHERE tie_count > possible_pairs
    """
).fetchone()[0]
if violation_count:
    raise RuntimeError(
        f"Found {violation_count:,} topic-year rows with impossible tie counts"
    )

connection.execute(
    f"""
    COPY no_upper_limit_temporal_coordination_topic_year_six
    TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

family_contribution_path = (
    OUTPUT_DIRECTORY / "no_upper_limit_family_size_contribution_by_field.csv"
)
connection.execute(
    f"""
    COPY (
        WITH family AS (
            SELECT
                member.universe,
                article.analytic_field,
                member.focal_work_id,
                ANY_VALUE(member.clean_family_size) AS memberships,
                ANY_VALUE(opportunity.within_possible_pairs)
                  + ANY_VALUE(opportunity.cross_possible_pairs)
                    AS possible_pairs,
                COALESCE(ANY_VALUE(realized.within_ties), 0)
                  + COALESCE(ANY_VALUE(realized.cross_ties), 0)
                    AS realized_ties
            FROM no_upper_limit_temporal_coordination_members_six AS member
            INNER JOIN no_upper_limit_temporal_coordination_opportunities_six
                AS opportunity USING (universe, focal_work_id)
            INNER JOIN analysis_articles AS article
              ON member.universe = article.universe
             AND member.focal_work_id = article.work_id
            LEFT JOIN no_upper_limit_temporal_coordination_realized_six
                AS realized USING (universe, focal_work_id)
            GROUP BY member.universe, article.analytic_field,
                     member.focal_work_id
        ),
        grouped AS (
            SELECT
                universe,
                analytic_field,
                CASE WHEN memberships <= 20 THEN '2-20' ELSE '21+' END
                    AS size_group,
                COUNT(*) AS focal_families,
                SUM(memberships) AS memberships,
                SUM(possible_pairs) AS possible_pairs,
                SUM(realized_ties) AS realized_ties
            FROM family
            GROUP BY universe, analytic_field, size_group
        )
        SELECT
            *,
            100.0 * focal_families /
              SUM(focal_families) OVER (PARTITION BY universe, analytic_field)
                AS family_share_pct,
            100.0 * possible_pairs /
              SUM(possible_pairs) OVER (PARTITION BY universe, analytic_field)
                AS pair_share_pct,
            100.0 * realized_ties /
              SUM(realized_ties) OVER (PARTITION BY universe, analytic_field)
                AS tie_share_pct
        FROM grouped
        ORDER BY universe, analytic_field, size_group
    ) TO '{family_contribution_path}' (HEADER, DELIMITER ',')
    """
)

print(
    connection.execute(
        """
        SELECT
            universe,
            analytic_field,
            pair_type,
            COUNT(*) AS topic_years,
            SUM(focal_families) AS focal_families,
            SUM(tie_count) AS ties,
            SUM(possible_pairs) AS possible_pairs,
            1000.0 * SUM(tie_count) / SUM(possible_pairs)
                AS ties_per_1000_opportunities
        FROM no_upper_limit_temporal_coordination_topic_year_six
        GROUP BY universe, analytic_field, pair_type
        ORDER BY universe, analytic_field, pair_type
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

print(f"Wrote {output_path}", flush=True)
print(f"Wrote {family_contribution_path}", flush=True)
connection.close()
