#!/usr/bin/env python3
"""Build corresponding-researcher attention outcomes from citation families."""

from __future__ import annotations

import time

import duckdb


connection = duckdb.connect("/private/tmp/journal_structure_six.duckdb")
connection.execute("SET threads=8")
connection.execute("SET memory_limit='32GB'")
connection.execute("SET temp_directory='/private/tmp/duckdb_researcher_attention_tmp'")
connection.execute("SET preserve_insertion_order=FALSE")


def exists(table: str) -> bool:
    """Return whether a persistent table exists."""
    return bool(connection.execute(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?",
        [table],
    ).fetchone()[0])


def stage(table: str, query: str) -> None:
    """Create a resumable stage and report elapsed time."""
    if exists(table):
        print(f"Reuse {table}", flush=True)
        return
    started = time.time()
    connection.execute(f"CREATE TABLE {table} AS {query}")
    count = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    print(f"Built {table}: {count:,} rows in {time.time() - started:.1f}s", flush=True)


stage(
    "researcher_attention_cohort_six",
    """
    SELECT
        universe,
        corresponding_author_id AS author_id,
        corresponding_institution_id AS institution_id,
        analytic_field,
        publication_year AS cohort_year,
        work_id AS focal_work_id,
        topic_id,
        citations_3y,
        citation_z_3y,
        log_eff_j,
        cell_n,
        log_authors,
        oa_value,
        field_year_id
    FROM analysis_articles
    WHERE corresponding_author_id IS NOT NULL
      AND corresponding_institution_id IS NOT NULL
      AND cell_n >= 20
    """,
)

stage(
    "researcher_attention_members_six",
    """
    SELECT DISTINCT
        cohort.universe,
        cohort.author_id,
        cohort.institution_id,
        cohort.analytic_field,
        cohort.cohort_year,
        member.citing_work_id,
        citer.author_id AS citing_author_id,
        member.citing_institution_id,
        member.citing_country_code,
        member.citing_topic_id,
        member.citing_field_id
    FROM researcher_attention_cohort_six AS cohort
    INNER JOIN attention_member_six AS member
      ON cohort.universe = member.universe
     AND cohort.focal_work_id = member.focal_work_id
     AND member.horizon = 3
    LEFT JOIN citer_corresponding_institution_six AS citer
      ON member.citing_work_id = citer.work_id
    """,
)

stage(
    "researcher_attention_topic_stats_six",
    """
    WITH counts AS (
        SELECT universe, author_id, institution_id, analytic_field,
               cohort_year, citing_topic_id, COUNT(*) AS attention_count
        FROM researcher_attention_members_six
        WHERE citing_topic_id IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(attention_count) OVER panel AS total_attention
        FROM counts
        WINDOW panel AS (
            PARTITION BY universe, author_id, institution_id,
                         analytic_field, cohort_year
        )
    )
    SELECT universe, author_id, institution_id, analytic_field, cohort_year,
           COUNT(*) AS distinct_attention_topics,
           1.0 / SUM(POWER(attention_count * 1.0 / total_attention, 2))
               AS effective_attention_topics
    FROM totals
    GROUP BY universe, author_id, institution_id, analytic_field, cohort_year
    """,
)

stage(
    "researcher_attention_institution_stats_six",
    """
    WITH counts AS (
        SELECT universe, author_id, institution_id, analytic_field,
               cohort_year, citing_institution_id,
               COUNT(*) AS attention_count
        FROM researcher_attention_members_six
        WHERE citing_institution_id IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(attention_count) OVER panel AS total_attention
        FROM counts
        WINDOW panel AS (
            PARTITION BY universe, author_id, institution_id,
                         analytic_field, cohort_year
        )
    )
    SELECT universe, author_id, institution_id, analytic_field, cohort_year,
           COUNT(*) AS distinct_attention_institutions,
           1.0 / SUM(POWER(attention_count * 1.0 / total_attention, 2))
               AS effective_attention_institutions
    FROM totals
    GROUP BY universe, author_id, institution_id, analytic_field, cohort_year
    """,
)

stage(
    "researcher_attention_country_stats_six",
    """
    WITH counts AS (
        SELECT universe, author_id, institution_id, analytic_field,
               cohort_year, citing_country_code,
               COUNT(*) AS attention_count
        FROM researcher_attention_members_six
        WHERE citing_country_code IS NOT NULL
        GROUP BY ALL
    ),
    totals AS (
        SELECT *, SUM(attention_count) OVER panel AS total_attention
        FROM counts
        WINDOW panel AS (
            PARTITION BY universe, author_id, institution_id,
                         analytic_field, cohort_year
        )
    )
    SELECT universe, author_id, institution_id, analytic_field, cohort_year,
           COUNT(*) AS distinct_attention_countries,
           1.0 / SUM(POWER(attention_count * 1.0 / total_attention, 2))
               AS effective_attention_countries
    FROM totals
    GROUP BY universe, author_id, institution_id, analytic_field, cohort_year
    """,
)

stage(
    "researcher_attention_amount_six",
    """
    SELECT
        universe, author_id, institution_id, analytic_field, cohort_year,
        COUNT(*) AS unique_citing_works,
        COUNT(DISTINCT citing_author_id) AS unique_citing_authors,
        COUNT(DISTINCT citing_field_id) AS distinct_attention_fields,
        AVG(CAST(citing_author_id IS NOT NULL AND
                 citing_author_id <> author_id AS DOUBLE))
            AS external_attention_share
    FROM researcher_attention_members_six
    GROUP BY ALL
    """,
)

stage(
    "researcher_attention_portfolio_six",
    """
    WITH paper_attention AS (
        SELECT
            cohort.universe,
            cohort.author_id,
            cohort.institution_id,
            cohort.analytic_field,
            cohort.cohort_year,
            cohort.focal_work_id,
            cohort.citations_3y,
            cohort.citation_z_3y,
            cohort.log_eff_j,
            cohort.cell_n,
            cohort.log_authors,
            cohort.oa_value,
            cohort.field_year_id,
            COALESCE(conversation.n_citers, 0) AS n_citers
        FROM researcher_attention_cohort_six AS cohort
        LEFT JOIN conversation_outcomes_six AS conversation
          ON cohort.universe = conversation.universe
         AND cohort.focal_work_id = conversation.focal_work_id
         AND conversation.horizon = 3
    ),
    totals AS (
        SELECT
            *,
            SUM(n_citers) OVER panel AS panel_citers
        FROM paper_attention
        WINDOW panel AS (
            PARTITION BY universe, author_id, institution_id,
                         analytic_field, cohort_year
        )
    )
    SELECT
        universe, author_id, institution_id, analytic_field, cohort_year,
        ANY_VALUE(field_year_id) AS field_year_id,
        COUNT(*) AS focal_papers,
        AVG(log_eff_j) AS mean_log_eff_j,
        AVG(LN(cell_n)) AS mean_log_cell_n,
        AVG(log_authors) AS mean_log_authors,
        AVG(oa_value) AS oa_share,
        SUM(citations_3y) AS total_citations_3y,
        AVG(citation_z_3y) AS mean_citation_z_3y,
        SUM(n_citers) AS paper_summed_citers,
        CASE WHEN ANY_VALUE(panel_citers) > 0 THEN
            MAX(n_citers) * 1.0 / ANY_VALUE(panel_citers)
            ELSE NULL END AS top_paper_attention_share,
        CASE WHEN ANY_VALUE(panel_citers) > 0 THEN
            SUM(POWER(n_citers * 1.0 / panel_citers, 2))
            ELSE NULL END AS portfolio_attention_hhi
    FROM totals
    GROUP BY universe, author_id, institution_id, analytic_field, cohort_year
    """,
)

stage(
    "researcher_attention_panel_six",
    """
    SELECT
        portfolio.*,
        amount.unique_citing_works,
        amount.unique_citing_authors,
        amount.distinct_attention_fields,
        amount.external_attention_share,
        topic.distinct_attention_topics,
        topic.effective_attention_topics,
        institution.distinct_attention_institutions,
        institution.effective_attention_institutions,
        country.distinct_attention_countries,
        country.effective_attention_countries
    FROM researcher_attention_portfolio_six AS portfolio
    LEFT JOIN researcher_attention_amount_six AS amount USING (
        universe, author_id, institution_id, analytic_field, cohort_year
    )
    LEFT JOIN researcher_attention_topic_stats_six AS topic USING (
        universe, author_id, institution_id, analytic_field, cohort_year
    )
    LEFT JOIN researcher_attention_institution_stats_six AS institution USING (
        universe, author_id, institution_id, analytic_field, cohort_year
    )
    LEFT JOIN researcher_attention_country_stats_six AS country USING (
        universe, author_id, institution_id, analytic_field, cohort_year
    )
    """,
)

connection.execute(
    """
    COPY researcher_attention_panel_six
    TO '/private/tmp/researcher_attention_panel_six.parquet'
    (FORMAT PARQUET, COMPRESSION ZSTD)
    """
)

print(connection.execute(
    """
    SELECT universe, analytic_field, COUNT(*) AS researcher_years,
           AVG(focal_papers) AS mean_focal_papers,
           AVG(unique_citing_works) AS mean_unique_citing_works,
           AVG(unique_citing_authors) AS mean_unique_citing_authors,
           AVG(effective_attention_topics) AS mean_effective_topics
    FROM researcher_attention_panel_six
    GROUP BY ALL
    ORDER BY universe, analytic_field
    """
).fetchdf().to_string(index=False))
