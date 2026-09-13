#!/usr/bin/env python3
"""Build main-model panels after excluding corresponding-author self-citations.

The current outcome compares realized citation ties among follow-on papers.
Author self-citations are defined here as realized ties for which the selected
corresponding author is identical on the later and earlier paper. Potential
citation opportunities remain in the denominator, matching the usual practice
of removing self-citation edges rather than changing the risk set.

Two sensitivity samples are built:

1. all eligible families, with observed corresponding-author self-citations
   removed; and
2. families for which every follow-on paper has a selected corresponding
   author, again with self-citations removed.

The pair-level audit separately uses complete author lists to remove any-author
overlap, which is a stricter definition than the selected-author definition
available for the full main-model population.
"""

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
    "SET temp_directory='/private/tmp/duckdb_self_citation_sensitivity_tmp'"
)
connection.execute("SET preserve_insertion_order=FALSE")


def build_table(name: str, query: str) -> None:
    """Replace a derived table and report its row count and build time."""
    started = time.time()
    connection.execute(f"CREATE OR REPLACE TABLE {name} AS {query}")
    row_count = connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
    print(
        f"Built {name}: {row_count:,} rows in {time.time() - started:.1f}s",
        flush=True,
    )


build_table(
    "temporal_selected_corresponding_author_six",
    """
    SELECT
        work_id,
        MIN(author_id) AS author_id,
        COUNT(DISTINCT author_id) AS selected_author_count
    FROM citer_corresponding_institution_six
    WHERE author_id IS NOT NULL
    GROUP BY work_id
    """,
)

build_table(
    "temporal_author_coverage_family_six",
    """
    SELECT
        member.universe,
        member.focal_work_id,
        COUNT(*) AS member_count,
        COUNT(author.author_id) AS member_count_with_author,
        CAST(COUNT(*) = COUNT(author.author_id) AS INTEGER)
            AS complete_corresponding_author_family
    FROM temporal_coordination_members_six AS member
    LEFT JOIN temporal_selected_corresponding_author_six AS author
      ON member.citing_work_id = author.work_id
    GROUP BY member.universe, member.focal_work_id
    """,
)

build_table(
    "temporal_coordination_realized_self_citation_six",
    """
    WITH eligible_pairs AS (
        SELECT
            pair.universe,
            pair.focal_work_id,
            pair.later_work_id,
            pair.earlier_work_id,
            later.citing_source_id AS later_source_id,
            earlier.citing_source_id AS earlier_source_id,
            later_author.author_id AS later_author_id,
            earlier_author.author_id AS earlier_author_id,
            CAST(
                later_author.author_id IS NOT NULL
                AND earlier_author.author_id IS NOT NULL
                AND later_author.author_id = earlier_author.author_id
                AS INTEGER
            ) AS corresponding_author_self_citation
        FROM conversation_pair_horizon_six AS pair
        INNER JOIN temporal_coordination_members_six AS later
          ON pair.universe = later.universe
         AND pair.focal_work_id = later.focal_work_id
         AND pair.later_work_id = later.citing_work_id
        INNER JOIN temporal_coordination_members_six AS earlier
          ON pair.universe = earlier.universe
         AND pair.focal_work_id = earlier.focal_work_id
         AND pair.earlier_work_id = earlier.citing_work_id
        LEFT JOIN temporal_selected_corresponding_author_six AS later_author
          ON pair.later_work_id = later_author.work_id
        LEFT JOIN temporal_selected_corresponding_author_six AS earlier_author
          ON pair.earlier_work_id = earlier_author.work_id
        WHERE pair.horizon = 3
          AND later.citing_date > earlier.citing_date
    )
    SELECT
        universe,
        focal_work_id,
        COUNT(*) FILTER (
            WHERE later_source_id = earlier_source_id
        ) AS within_ties_all,
        COUNT(*) FILTER (
            WHERE later_source_id <> earlier_source_id
        ) AS cross_ties_all,
        COUNT(*) FILTER (
            WHERE later_source_id = earlier_source_id
              AND corresponding_author_self_citation = 0
        ) AS within_ties_nonself,
        COUNT(*) FILTER (
            WHERE later_source_id <> earlier_source_id
              AND corresponding_author_self_citation = 0
        ) AS cross_ties_nonself,
        COUNT(*) FILTER (
            WHERE later_source_id = earlier_source_id
              AND corresponding_author_self_citation = 1
        ) AS within_ties_self,
        COUNT(*) FILTER (
            WHERE later_source_id <> earlier_source_id
              AND corresponding_author_self_citation = 1
        ) AS cross_ties_self,
        COUNT(*) FILTER (
            WHERE later_author_id IS NOT NULL
              AND earlier_author_id IS NOT NULL
        ) AS ties_with_complete_author_pair
    FROM eligible_pairs
    GROUP BY universe, focal_work_id
    """,
)


build_table(
    "self_citation_topic_year_panel_six",
    """
    WITH allowed AS (
        SELECT DISTINCT
            universe,
            analytic_field,
            publication_year,
            topic_id,
            field_year_id,
            log_eff_j
        FROM temporal_coordination_topic_year_six
    ),
    self_counts AS (
        SELECT
            article.universe,
            article.analytic_field,
            article.publication_year,
            article.topic_id,
            article.field_year_id,
            SUM(COALESCE(realized.within_ties_self, 0)) AS within_ties_self,
            SUM(COALESCE(realized.cross_ties_self, 0)) AS cross_ties_self
        FROM temporal_coordination_opportunities_six AS opportunity
        INNER JOIN analysis_articles AS article
          ON opportunity.universe = article.universe
         AND opportunity.focal_work_id = article.work_id
        LEFT JOIN temporal_coordination_realized_self_citation_six AS realized
          ON opportunity.universe = realized.universe
         AND opportunity.focal_work_id = realized.focal_work_id
        INNER JOIN allowed
          ON article.universe = allowed.universe
         AND article.analytic_field = allowed.analytic_field
         AND article.publication_year = allowed.publication_year
         AND article.topic_id = allowed.topic_id
         AND article.field_year_id = allowed.field_year_id
        GROUP BY article.universe, article.analytic_field,
                 article.publication_year, article.topic_id,
                 article.field_year_id
    ),
    original_rows AS (
        SELECT
            sensitivity,
            CONCAT(sensitivity, '||', original.panel_id) AS panel_id,
            original.universe,
            original.analytic_field,
            original.publication_year,
            original.topic_id,
            original.field_year_id,
            original.log_eff_j,
            original.focal_families,
            original.is_cross_journal,
            original.pair_type,
            original.tie_count - CASE
                WHEN sensitivity = 'all_ties' THEN 0
                WHEN original.is_cross_journal = 1
                    THEN COALESCE(self_counts.cross_ties_self, 0)
                ELSE COALESCE(self_counts.within_ties_self, 0)
            END AS tie_count,
            original.possible_pairs
        FROM temporal_coordination_topic_year_six AS original
        CROSS JOIN (
            VALUES
                ('all_ties'),
                ('exclude_same_corresponding_author')
        ) AS specifications(sensitivity)
        LEFT JOIN self_counts USING (
            universe, analytic_field, publication_year, topic_id,
            field_year_id
        )
    ),
    complete_aggregated AS (
        SELECT
            article.universe,
            article.analytic_field,
            article.publication_year,
            article.topic_id,
            article.field_year_id,
            ANY_VALUE(allowed.log_eff_j) AS log_eff_j,
            COUNT(*) AS focal_families,
            SUM(opportunity.within_possible_pairs) AS within_possible_pairs,
            SUM(opportunity.cross_possible_pairs) AS cross_possible_pairs,
            SUM(COALESCE(realized.within_ties_nonself, 0)) AS within_ties,
            SUM(COALESCE(realized.cross_ties_nonself, 0)) AS cross_ties
        FROM temporal_coordination_opportunities_six AS opportunity
        INNER JOIN temporal_author_coverage_family_six AS coverage
          ON opportunity.universe = coverage.universe
         AND opportunity.focal_work_id = coverage.focal_work_id
         AND coverage.complete_corresponding_author_family = 1
        INNER JOIN analysis_articles AS article
          ON opportunity.universe = article.universe
         AND opportunity.focal_work_id = article.work_id
        INNER JOIN allowed
          ON article.universe = allowed.universe
         AND article.analytic_field = allowed.analytic_field
         AND article.publication_year = allowed.publication_year
         AND article.topic_id = allowed.topic_id
         AND article.field_year_id = allowed.field_year_id
        LEFT JOIN temporal_coordination_realized_self_citation_six AS realized
          ON opportunity.universe = realized.universe
         AND opportunity.focal_work_id = realized.focal_work_id
        GROUP BY article.universe, article.analytic_field,
                 article.publication_year, article.topic_id,
                 article.field_year_id
    ),
    complete_rows AS (
        SELECT
            'complete_author_families_exclude_same' AS sensitivity,
            CONCAT(
                'complete_author_families_exclude_same||',
                universe, '||', analytic_field, '||', publication_year,
                '||', topic_id
            ) AS panel_id,
            universe,
            analytic_field,
            publication_year,
            topic_id,
            field_year_id,
            log_eff_j,
            focal_families,
            0 AS is_cross_journal,
            'within' AS pair_type,
            within_ties AS tie_count,
            within_possible_pairs AS possible_pairs
        FROM complete_aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
        UNION ALL
        SELECT
            'complete_author_families_exclude_same' AS sensitivity,
            CONCAT(
                'complete_author_families_exclude_same||',
                universe, '||', analytic_field, '||', publication_year,
                '||', topic_id
            ) AS panel_id,
            universe,
            analytic_field,
            publication_year,
            topic_id,
            field_year_id,
            log_eff_j,
            focal_families,
            1 AS is_cross_journal,
            'cross' AS pair_type,
            cross_ties AS tie_count,
            cross_possible_pairs AS possible_pairs
        FROM complete_aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
    )
    SELECT * FROM original_rows
    UNION ALL
    SELECT * FROM complete_rows
    """,
)

build_table(
    "self_citation_researcher_panel_six",
    """
    WITH allowed AS (
        SELECT DISTINCT
            panel_id,
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year,
            field_year_id,
            topic_id,
            log_eff_j
        FROM temporal_researcher_coordination_six
    ),
    self_counts AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            cohort.field_year_id,
            cohort.topic_id,
            cohort.topic_id,
            SUM(COALESCE(realized.within_ties_self, 0)) AS within_ties_self,
            SUM(COALESCE(realized.cross_ties_self, 0)) AS cross_ties_self
        FROM researcher_attention_cohort_six AS cohort
        INNER JOIN temporal_coordination_opportunities_six AS opportunity
          ON cohort.universe = opportunity.universe
         AND cohort.focal_work_id = opportunity.focal_work_id
        LEFT JOIN temporal_coordination_realized_self_citation_six AS realized
          ON cohort.universe = realized.universe
         AND cohort.focal_work_id = realized.focal_work_id
        INNER JOIN allowed
          ON cohort.universe = allowed.universe
         AND cohort.author_id = allowed.author_id
         AND cohort.institution_id = allowed.institution_id
         AND cohort.analytic_field = allowed.analytic_field
         AND cohort.cohort_year = allowed.cohort_year
         AND cohort.topic_id = allowed.topic_id
        GROUP BY cohort.universe, cohort.author_id, cohort.institution_id,
                 cohort.analytic_field, cohort.cohort_year,
                 cohort.field_year_id, cohort.topic_id
    ),
    original_rows AS (
        SELECT
            sensitivity,
            CONCAT(sensitivity, '||', original.panel_id) AS panel_id,
            original.universe,
            original.author_id,
            original.institution_id,
            original.analytic_field,
            original.cohort_year,
            original.field_year_id,
            original.topic_id,
            original.log_eff_j,
            original.focal_families,
            original.is_cross_journal,
            original.pair_type,
            original.tie_count - CASE
                WHEN sensitivity = 'all_ties' THEN 0
                WHEN original.is_cross_journal = 1
                    THEN COALESCE(self_counts.cross_ties_self, 0)
                ELSE COALESCE(self_counts.within_ties_self, 0)
            END AS tie_count,
            original.possible_pairs
        FROM temporal_researcher_coordination_six AS original
        CROSS JOIN (
            VALUES
                ('all_ties'),
                ('exclude_same_corresponding_author')
        ) AS specifications(sensitivity)
        LEFT JOIN self_counts USING (
            universe, author_id, institution_id, analytic_field,
            cohort_year, field_year_id, topic_id
        )
    ),
    complete_aggregated AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            cohort.field_year_id,
            cohort.topic_id,
            ANY_VALUE(allowed.panel_id) AS original_panel_id,
            ANY_VALUE(allowed.log_eff_j) AS log_eff_j,
            COUNT(*) AS focal_families,
            SUM(opportunity.within_possible_pairs) AS within_possible_pairs,
            SUM(opportunity.cross_possible_pairs) AS cross_possible_pairs,
            SUM(COALESCE(realized.within_ties_nonself, 0)) AS within_ties,
            SUM(COALESCE(realized.cross_ties_nonself, 0)) AS cross_ties
        FROM researcher_attention_cohort_six AS cohort
        INNER JOIN temporal_coordination_opportunities_six AS opportunity
          ON cohort.universe = opportunity.universe
         AND cohort.focal_work_id = opportunity.focal_work_id
        INNER JOIN temporal_author_coverage_family_six AS coverage
          ON cohort.universe = coverage.universe
         AND cohort.focal_work_id = coverage.focal_work_id
         AND coverage.complete_corresponding_author_family = 1
        INNER JOIN allowed
          ON cohort.universe = allowed.universe
         AND cohort.author_id = allowed.author_id
         AND cohort.institution_id = allowed.institution_id
         AND cohort.analytic_field = allowed.analytic_field
         AND cohort.cohort_year = allowed.cohort_year
         AND cohort.topic_id = allowed.topic_id
        LEFT JOIN temporal_coordination_realized_self_citation_six AS realized
          ON cohort.universe = realized.universe
         AND cohort.focal_work_id = realized.focal_work_id
        GROUP BY cohort.universe, cohort.author_id, cohort.institution_id,
                 cohort.analytic_field, cohort.cohort_year,
                 cohort.field_year_id, cohort.topic_id
    ),
    complete_rows AS (
        SELECT
            'complete_author_families_exclude_same' AS sensitivity,
            CONCAT(
                'complete_author_families_exclude_same||', original_panel_id
            ) AS panel_id,
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year,
            field_year_id,
            topic_id,
            log_eff_j,
            focal_families,
            0 AS is_cross_journal,
            'within' AS pair_type,
            within_ties AS tie_count,
            within_possible_pairs AS possible_pairs
        FROM complete_aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
        UNION ALL
        SELECT
            'complete_author_families_exclude_same' AS sensitivity,
            CONCAT(
                'complete_author_families_exclude_same||', original_panel_id
            ) AS panel_id,
            universe,
            author_id,
            institution_id,
            analytic_field,
            cohort_year,
            field_year_id,
            topic_id,
            log_eff_j,
            focal_families,
            1 AS is_cross_journal,
            'cross' AS pair_type,
            cross_ties AS tie_count,
            cross_possible_pairs AS possible_pairs
        FROM complete_aggregated
        WHERE within_possible_pairs > 0
          AND cross_possible_pairs > 0
    )
    SELECT * FROM original_rows
    UNION ALL
    SELECT * FROM complete_rows
    """,
)

topic_output = OUTPUT_DIRECTORY / "self_citation_topic_year_panel.parquet"
researcher_output = OUTPUT_DIRECTORY / "self_citation_researcher_panel.parquet"
connection.execute(
    f"COPY self_citation_topic_year_panel_six TO '{topic_output}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)
connection.execute(
    f"COPY self_citation_researcher_panel_six TO '{researcher_output}' "
    "(FORMAT PARQUET, COMPRESSION ZSTD)"
)

summary_output = OUTPUT_DIRECTORY / "self_citation_descriptives.csv"
connection.execute(
    f"""
    COPY (
        WITH family_summary AS (
            SELECT
                coverage.universe,
                COUNT(*) AS focal_families,
                AVG(coverage.complete_corresponding_author_family)
                    AS complete_author_family_share,
                SUM(COALESCE(realized.within_ties_all, 0))
                    AS within_ties_all,
                SUM(COALESCE(realized.cross_ties_all, 0))
                    AS cross_ties_all,
                SUM(COALESCE(realized.within_ties_self, 0))
                    AS within_ties_self,
                SUM(COALESCE(realized.cross_ties_self, 0))
                    AS cross_ties_self
            FROM temporal_author_coverage_family_six AS coverage
            LEFT JOIN temporal_coordination_realized_self_citation_six AS realized
              USING (universe, focal_work_id)
            GROUP BY coverage.universe
        )
        SELECT
            *,
            within_ties_self * 1.0 / NULLIF(within_ties_all, 0)
                AS within_corresponding_author_self_share,
            cross_ties_self * 1.0 / NULLIF(cross_ties_all, 0)
                AS cross_corresponding_author_self_share
        FROM family_summary
        ORDER BY universe
    ) TO '{summary_output}' (HEADER, DELIMITER ',')
    """
)

print(
    connection.execute(
        """
        SELECT *
        FROM read_csv_auto('results/direct_outcome_gap/self_citation_descriptives.csv')
        ORDER BY universe
        """
    ).fetchdf().to_string(index=False),
    flush=True,
)

connection.close()
