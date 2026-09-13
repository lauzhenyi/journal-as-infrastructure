#!/usr/bin/env python3
"""Build researcher citation-family integration for two-, three-, and five-year windows."""

from __future__ import annotations

import time

import duckdb


connection = duckdb.connect("/private/tmp/journal_structure_six.duckdb")
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_researcher_windows_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


started = time.time()
connection.execute(
    """
    CREATE OR REPLACE TABLE researcher_portfolio_integration_windows_six AS
    WITH paper_families AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            cohort.focal_work_id,
            conversation.horizon,
            conversation.n_citers,
            conversation.possible_pairs,
            conversation.cross_journal_possible_pairs,
            conversation.same_journal_possible_pairs,
            conversation.internal_ties,
            conversation.cross_journal_ties,
            conversation.within_journal_ties,
            conversation.isolated_citer_share
        FROM researcher_attention_cohort_six AS cohort
        INNER JOIN conversation_outcomes_six AS conversation
          ON cohort.universe = conversation.universe
         AND cohort.focal_work_id = conversation.focal_work_id
         AND conversation.horizon IN (2, 3, 5)
    ),
    aggregated AS (
        SELECT
            universe, author_id, institution_id, analytic_field, cohort_year,
            horizon,
            COUNT(*) AS papers_with_citation_families,
            SUM(n_citers) AS summed_family_citers,
            SUM(possible_pairs) AS summed_possible_pairs,
            SUM(cross_journal_possible_pairs)
                AS summed_cross_journal_possible_pairs,
            SUM(same_journal_possible_pairs)
                AS summed_same_journal_possible_pairs,
            SUM(internal_ties) AS summed_internal_ties,
            SUM(cross_journal_ties) AS summed_cross_journal_ties,
            SUM(within_journal_ties) AS summed_within_journal_ties,
            SUM(isolated_citer_share * n_citers) / SUM(n_citers)
                AS portfolio_isolated_citer_share
        FROM paper_families
        GROUP BY ALL
    )
    SELECT
        panel.*,
        aggregated.horizon,
        aggregated.papers_with_citation_families,
        aggregated.summed_family_citers,
        CASE WHEN aggregated.summed_possible_pairs > 0 THEN
            100.0 * aggregated.summed_internal_ties /
            aggregated.summed_possible_pairs
            ELSE NULL END AS portfolio_internal_tie_density_pp,
        CASE WHEN aggregated.summed_cross_journal_possible_pairs > 0 THEN
            100.0 * aggregated.summed_cross_journal_ties /
            aggregated.summed_cross_journal_possible_pairs
            ELSE NULL END AS portfolio_cross_journal_tie_density_pp,
        CASE WHEN aggregated.summed_same_journal_possible_pairs > 0 THEN
            100.0 * aggregated.summed_within_journal_ties /
            aggregated.summed_same_journal_possible_pairs
            ELSE NULL END AS portfolio_within_journal_tie_density_pp,
        aggregated.portfolio_isolated_citer_share,
        CASE WHEN aggregated.summed_cross_journal_possible_pairs > 0
                  AND aggregated.summed_same_journal_possible_pairs > 0 THEN
            100.0 * aggregated.summed_within_journal_ties /
                aggregated.summed_same_journal_possible_pairs -
            100.0 * aggregated.summed_cross_journal_ties /
                aggregated.summed_cross_journal_possible_pairs
            ELSE NULL END AS venue_localization_gap_pp
    FROM researcher_attention_panel_six AS panel
    INNER JOIN aggregated USING (
        universe, author_id, institution_id, analytic_field, cohort_year
    )
    """
)

row_count = connection.execute(
    "SELECT COUNT(*) FROM researcher_portfolio_integration_windows_six"
).fetchone()[0]
print(
    f"Built researcher_portfolio_integration_windows_six: {row_count:,} rows "
    f"in {time.time() - started:.1f}s",
    flush=True,
)

connection.execute(
    """
    COPY researcher_portfolio_integration_windows_six
    TO '/private/tmp/researcher_portfolio_integration_windows_six.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, horizon, COUNT(*) AS researcher_years,
           AVG(venue_localization_gap_pp) AS mean_localization_gap_pp,
           AVG(portfolio_cross_journal_tie_density_pp)
               AS mean_cross_journal_density_pp,
           AVG(portfolio_isolated_citer_share) AS mean_isolated_share
    FROM researcher_portfolio_integration_windows_six
    GROUP BY ALL
    ORDER BY universe, horizon
    """
).fetchdf().to_string(index=False))
